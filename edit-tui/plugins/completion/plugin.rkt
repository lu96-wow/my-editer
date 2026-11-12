#lang racket

;;; edit-tui/plugins/completion/plugin.rkt —— 补全菜单（第一阶段）
;;;
;;; 流程：
;;;   changes -> 取消旧 timer，schedule 180ms
;;;   timer   -> 本地候选同步开菜单 + 提交 completion job
;;;   job     -> 校验 request-id，更新候选
;;;   菜单    -> overlay 显示候选；Up/Down/Tab/Enter/Esc
;;;
;;; 候选来源先只做当前 buffer（completion-candidates/local）；workspace 后续接。
;;; 跨插件请求只发 action（show-docs-action），不直接写 docs 的 plugin-state。

(require racket/match
         (only-in racket/list take)
         racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt"
         "../../compat/lang/racket/api.rkt"
         "../../features/input/api.rkt"
         "../../features/placement/api.rkt")

(provide make-completion-plugin
         (struct-out completion-state))

(struct completion-state
  (view-id
   target-vid
   target-did
   target-version
   prefix
   candidates
   index
   open?
   request-id
   timer-id
   anchor-line
   anchor-col
   suppress-next?
   popup-rect
   inner-width)
  #:transparent)

(define (empty-completion-state view-id)
  (completion-state view-id #f #f #f "" '() 0 #f #f #f 0 0 #f #f 1))

;; → (list vid did) | #f
(define (current-target ed state)
  (define vid (editor-focus-view-id state))
  (define did (and vid (editor-view-doc-id ed vid)))
  (and vid did (eq? (state-doc-mode state did) 'racket)
       (list vid did)))

(define (resource-path-for-state state vid)
  (define r (and vid (state-resource-for-view state vid)))
  (and r (resource-path r)))

(define (prefix-at ed vid)
  (define text (editor-view-text ed vid))
  (define line (editor-view-point-line ed vid))
  (define col (editor-view-point-column ed vid))
  (and text line col (completion-prefix text line col)))

(define (all-candidates ed state vid did prefix local-only?)
  (define text (editor-doc-text ed did))
  (define path (resource-path-for-state state vid))
  (define ctx (and text (with-handlers ([exn:fail? (λ (_) #f)])
                          (make-completion-context path text))))
  (cond
    [(not ctx) '()]
    [local-only?
     (define local (completion-candidates/local ctx prefix))
     (take local (min 50 (length local)))]
    [else (completion-candidates ctx prefix)]))

(define (completion-focused? state c)
  (and (completion-state? c)
       (completion-state-open? c)
       (eq? (editor-focus-view-id state) (completion-state-target-vid c))))

(define (close-completion ps)
  (cond
    [(not (completion-state? ps)) ps]
    [else
     (struct-copy completion-state ps
                  [open? #f]
                  [candidates '()]
                  [index 0]
                  [request-id #f]
                  [popup-rect #f])]))

;;; ════════════════ 打开 / refine ════════════════

;; → (values state' ps' actions)
(define (open-completion! ed state ps vid did)
  (cond
    [(not (completion-state? ps)) (values state ps '())]
    [else
     (define prefix (prefix-at ed vid))
     (cond
       [(or (not prefix) (zero? (string-length prefix)))
        (values state (close-completion ps) '())]
       [else
        (define local (all-candidates ed state vid did prefix #t))
        (define c1
          (struct-copy completion-state ps
                       [target-vid vid]
                       [target-did did]
                       [target-version (editor-doc-version ed did)]
                       [prefix prefix]
                       [candidates local]
                       [index 0]
                       [open? (pair? local)]
                       [request-id #f]
                       [timer-id #f]
                       [anchor-line (editor-view-point-line ed vid)]
                       [anchor-col (editor-view-point-column ed vid)]
                       [popup-rect #f]))
        (define-values (state2 job)
          (state-submit-job state 'completion
                                   (list prefix (resource-path-for-state state vid)
                                         (editor-doc-text ed did))
                                   (list 'completion (editor-doc-version ed did))))
        (values state2
                (struct-copy completion-state c1 [request-id (job-id job)])
                (if (pair? local)
                    (list (show-docs-action (car local)))
                    '()))])]))

(define (handle-timer ed state ps ev)
  (cond
    [(not (completion-state? ps)) (values state ps '())]
    [(not (equal? (timer-event-id ev) (completion-state-timer-id ps)))
     (values state ps '())]
    [else
     (define ps1 (struct-copy completion-state ps [timer-id #f]))
     (cond
       [(editor-input-active? state) (values state ps1 '())]
       [(editor-placement-active? state) (values state ps1 '())]
       [else
        (define target (current-target ed state))
        (cond
          [(not target) (values state (close-completion ps1) '())]
          [else
           (match-define (list vid did) target)
           (open-completion! ed state ps1 vid did)])])]))

;;; ════════════════ changes hook ════════════════

(define (handle-changes ctx ps)
  (define ed (change-context-editor ctx))
  (define state (change-context-state ctx))
  (define did (change-context-doc-id ctx))
  (define version (change-context-version ctx))
  (cond
    [(not (completion-state? ps)) (values ctx ps '() #t)]
    [(completion-state-suppress-next? ps)
     (values ctx (struct-copy completion-state ps [suppress-next? #f]) '() #t)]
    [else
     (define fvid (editor-focus-view-id state))
     (define fdid (and fvid (editor-view-doc-id ed fvid)))
     (cond
       [(or (not fvid) (not (equal? did fdid))) (values ctx ps '() #t)]
       [else
        (define ps1
          (cond
            [(completion-state-open? ps)
             (struct-copy completion-state ps
                          [target-version version]
                          [anchor-line (editor-view-point-line
                                        ed (completion-state-target-vid ps))]
                          [anchor-col (editor-view-point-column
                                       ed (completion-state-target-vid ps))])]
            [else
             (struct-copy completion-state ps
                          [target-vid fvid]
                          [target-did did]
                          [target-version version]
                          [anchor-line (editor-view-point-line ed fvid)]
                          [anchor-col (editor-view-point-column ed fvid)])]))
        (define ps2
          (cond
            [(not (eq? (state-doc-mode state did) 'racket)) ps1]
            [else
             (editor-cancel-timer! ed (completion-state-timer-id ps1))
             (define tid (editor-schedule-timer! ed 180))
             (struct-copy completion-state ps1 [timer-id tid])]))
        (values ctx ps2 '() #t)])]))

;;; ════════════════ job result ════════════════

(define (handle-job ed state ps ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'completion)) (values state ps '())]
    [(not (completion-state? ps)) (values state ps '())]
    [(not (equal? (completion-state-request-id ps) (job-result-event-id ev)))
     (values state ps '())]
    [else
     (define result (job-result-event-result ev))
     (cond
       [(job-error? result)
        (values state (struct-copy completion-state ps [request-id #f]) '())]
       [(and (list? result) (andmap string? result))
        (cond
          [(null? result)
           (values state
                   (close-completion (struct-copy completion-state ps [request-id #f]))
                   '())]
          [else
           (define idx (min (completion-state-index ps) (sub1 (length result))))
           (define ps*
             (struct-copy completion-state ps
                          [candidates result]
                          [index idx]
                          [open? #t]
                          [request-id #f]))
           (values state ps*
                   (list (show-docs-action (list-ref result idx))))])]
       [else (values state (struct-copy completion-state ps [request-id #f]) '())])]))

;;; ════════════════ 命令 ════════════════

(define (move-selection ed state ps step)
  (cond
    [(or (not (completion-state? ps))
         (not (completion-state-open? ps))
         (null? (completion-state-candidates ps)))
     (values state ps '())]
    [else
     (define n (length (completion-state-candidates ps)))
     (define idx (modulo (+ (completion-state-index ps) step) n))
     (values state
             (struct-copy completion-state ps [index idx])
             (list (show-docs-action
                    (list-ref (completion-state-candidates ps) idx))))]))

(define (next-command ed state ps) (move-selection ed state ps 1))
(define (prev-command ed state ps) (move-selection ed state ps -1))

(define (accept-command ed state ps)
  (cond
    [(or (not (completion-state? ps))
         (not (completion-state-open? ps))
         (null? (completion-state-candidates ps)))
     (values state ps '())]
    [else
     (define idx (min (completion-state-index ps)
                      (sub1 (length (completion-state-candidates ps)))))
     (define cand (list-ref (completion-state-candidates ps) idx))
     (define ins (completion-insert-text cand (completion-state-prefix ps)))
     (define ps*
       (struct-copy completion-state ps
                    [open? #f]
                    [candidates '()]
                    [index 0]
                    [request-id #f]
                    [suppress-next? #t]
                    [popup-rect #f]))
     (cond
       [(zero? (string-length ins)) (values state ps* '())]
       [else
        (define-values (state* actions)
          (editor-insert! ed state (completion-state-target-vid ps) ins))
        (values state* ps* actions)])]))

(define (cancel-command ed state ps)
  (values state (close-completion ps) '()))

(define (manual-open-command ed state ps)
  (define target (current-target ed state))
  (cond
    [(not target)
     (values (state-with-flash state "completion: focus is not Racket editor")
             ps '())]
    [else
     (match-define (list vid did) target)
     (open-completion! ed state ps vid did)]))

;;; ════════════════ overlay / sync ════════════════

(define (fit-line s width)
  (define w (max 0 width))
  (cond
    [(<= (string-length s) w) (string-append s (make-string (- w (string-length s)) #\space))]
    [else (substring s 0 w)]))

(define (popup-geometry ed state c)
  (define content (editor-focus-content-rect state))
  (define vid (completion-state-target-vid c))
  (define cur (and content vid (editor-view-cursor-screen-position ed vid)))
  (define cands (completion-state-candidates c))
  (cond
    [(or (not content) (not cur) (null? cands)) #f]
    [else
     (define max-w (for/fold ([m 1]) ([x (in-list cands)]) (max m (string-length x))))
     (define outer-w (max 4 (min (+ max-w 2) (rect-w content))))
     (define inner-w (- outer-w 2))
     (define cursor-x (+ (rect-x content) (cdr cur)))
     (define cursor-y (+ (rect-y content) (car cur)))
     (define below-y (add1 cursor-y))
     (define below-space (max 0 (- (rect-bottom content) below-y)))
     (define above-space (max 0 (- cursor-y (rect-y content))))
     (define desired (length cands))
     (define below-cap (max 0 (- below-space 2)))
     (define above-cap (max 0 (- above-space 2)))
     (define use-below?
       (cond [(>= below-cap desired) #t]
             [(>= above-cap desired) #f]
             [else (>= below-cap above-cap)]))
     (define cap (if use-below? below-cap above-cap))
     (define inner-h (min desired cap))
     (cond
       [(<= inner-h 0) #f]
       [else
        (define outer-h (+ inner-h 2))
        (define x (max (rect-x content)
                       (min cursor-x (- (rect-right content) outer-w))))
        (define y (if use-below? below-y (- cursor-y outer-h)))
        (cons (rect x y outer-w outer-h) inner-w)])]))

;; → ps'
(define (sync-completion-view! ed state ps)
  (cond
    [(or (not (completion-state? ps))
         (not (completion-state-open? ps))
         (null? (completion-state-candidates ps)))
     (if (and (completion-state? ps) (completion-state-popup-rect ps))
         (struct-copy completion-state ps [popup-rect #f])
         ps)]
    [else
     (define g (popup-geometry ed state ps))
     (cond
       [(not g)
        (struct-copy completion-state ps [popup-rect #f])]
       [else
        (define r (car g))
        (define inner-w (cdr g))
        (define lines (for/list ([x (in-list (completion-state-candidates ps))])
                        (fit-line x inner-w)))
        (define idx (min (completion-state-index ps) (sub1 (length lines))))
        (define faces (for/list ([i (in-range (length lines))])
                        (if (= i idx) 'completion-selected 'completion)))
        (editor-set-view-content! ed (completion-state-view-id ps) lines faces)
        (editor-set-view-cursor! ed (completion-state-view-id ps) idx #:column 0)
        (struct-copy completion-state ps
                     [popup-rect r]
                     [inner-width inner-w])])]))

(define (sync-completion! ed state ps)
  (cond
    [(or (not (completion-state? ps)) (not (completion-state-open? ps)))
     (values state ps)]
    [else
     (define vid (completion-state-target-vid ps))
     (define did (completion-state-target-did ps))
     (define version (and did (editor-doc-version ed did)))
     (define line (and vid (editor-view-point-line ed vid)))
     (define col (and vid (editor-view-point-column ed vid)))
     (cond
       [(or (not vid) (not version) (not line) (not col))
        (values state (close-completion ps))]
       [(not (equal? version (completion-state-target-version ps)))
        (values state (close-completion ps))]
       [(and (= line (completion-state-anchor-line ps))
             (= col (completion-state-anchor-col ps)))
        (values state (sync-completion-view! ed state ps))]
       [else (values state (close-completion ps))])]))

(define (completion-overlays ed state ps)
  (cond
    [(and (completion-state? ps)
          (completion-state-open? ps)
          (completion-state-popup-rect ps))
     (list (make-editor-overlay (completion-state-view-id ps)
                                (completion-state-popup-rect ps)
                                #:face 'float-border
                                #:deep 100
                                #:weight 100))]
    [else '()]))

(define (service-completion payload)
  (match-define (list prefix path text) payload)
  (define ctx (and text (make-completion-context path text)))
  (and ctx (completion-candidates ctx prefix)))

(define completion-global-command-table
  (keys
   [(key 'o 'ctrl) manual-open-command]))

(define completion-command-table
  (keys
   [(key 'up) (make-guarded-command
               #:when (λ (ed state ps) (completion-focused? state ps))
               #:run prev-command)]
   [(key 'down) (make-guarded-command
                 #:when (λ (ed state ps) (completion-focused? state ps))
                 #:run next-command)]
   [(key 'tab) (make-guarded-command
                #:when (λ (ed state ps) (completion-focused? state ps))
                #:run next-command)]
   [(key 'enter) (make-guarded-command
                  #:when (λ (ed state ps) (completion-focused? state ps))
                  #:run accept-command)]
   [(key 'escape) (make-guarded-command
                   #:when (λ (ed state ps) (completion-focused? state ps))
                   #:run cancel-command)]
   [(key 'g 'ctrl) (make-guarded-command
                    #:when (λ (ed state ps) (completion-focused? state ps))
                    #:run cancel-command)]))

(define (make-completion-plugin #:view vid)
  (make-plugin
   #:id 'completion
   #:state (empty-completion-state vid)
   #:key-owner (λ (ed state ps)
                (and (completion-state? ps)
                     (completion-state-open? ps)
                     'completion))
   #:hooks
   (list
    (make-hook #:owner 'completion
               #:id 'changes
               #:operation 'changes
               #:phase 'observe
               #:fn handle-changes))
   #:sync sync-completion!
   #:services (list (service 'completion service-completion))
   #:handle-job handle-job
   #:handle-timer handle-timer
   #:overlays completion-overlays
   #:commands
   (list (command-group 'global completion-global-command-table)
         (command-group 'completion completion-command-table))))

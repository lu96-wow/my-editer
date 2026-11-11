#lang racket

;;; edit-tui-rebuild/plugins/completion/plugin.rkt —— 补全菜单（第一阶段）
;;;
;;; 流程：
;;;   changes -> 取消旧 timer，schedule 180ms
;;;   timer   -> 本地候选同步开菜单 + 提交 completion job
;;;   job     -> 校验 request-id，更新候选
;;;   菜单    -> overlay 显示候选；Up/Down/Tab/Enter/Esc
;;;
;;; 候选来源先只做当前 buffer（completion-candidates/local）；workspace 后续接。

(require racket/match
         (only-in racket/list take)
         racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt"
         "../../../edit-tui/lang/racket/api.rkt"
         "../docs/api.rkt"
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

(define (completion-state-of state)
  (let ([c (editor-state-plugin-state state 'completion)])
    (and (completion-state? c) c)))

(define (set-completion-state state c)
  (editor-state-set-plugin-state state 'completion c))

(define (current-target ed state)
  (define engine (editor-engine ed))
  (define vid (editor-focus-view-id state))
  (define did (and vid (engine-view-doc-id engine vid)))
  (and vid did (eq? (editor-state-doc-mode state did) 'racket)
       (values vid did)))

(define (resource-path-for-state state vid)
  (define r (and vid (editor-state-resource-for-view state vid)))
  (and r (resource-path r)))

(define (prefix-at engine vid)
  (define text (engine-view-text engine vid))
  (define line (engine-view-point-line engine vid))
  (define col (engine-view-point-column engine vid))
  (and text line col (completion-prefix text line col)))

(define (all-candidates ed state vid did prefix local-only?)
  (define engine (editor-engine ed))
  (define text (engine-doc-text engine did))
  (define path (resource-path-for-state state vid))
  (define ctx (and text (with-handlers ([exn:fail? (λ (_) #f)])
                          (make-completion-context path text))))
  (cond
    [(not ctx) '()]
    [local-only? (take (completion-candidates/local ctx prefix)
                       (min 50 (length (completion-candidates/local ctx prefix))))]
    [else (completion-candidates ctx prefix)]))

(define (completion-focused? state c)
  (and c (completion-state-open? c)
       (eq? (editor-focus-view-id state) (completion-state-target-vid c))))

(define (close-completion state)
  (define c (completion-state-of state))
  (cond
    [(not c) state]
    [else
     (set-completion-state state
                           (struct-copy completion-state c
                                        [open? #f]
                                        [candidates '()]
                                        [index 0]
                                        [request-id #f]
                                        [popup-rect #f]))]))

;;; ════════════════ 打开 / refine ════════════════

(define (open-completion! ed state vid did)
  (define engine (editor-engine ed))
  (define prefix (prefix-at engine vid))
  (cond
    [(or (not prefix) (zero? (string-length prefix))) (close-completion state)]
    [else
     (define local (all-candidates ed state vid did prefix #t))
     (define c0 (completion-state-of state))
     (define c1
       (struct-copy completion-state c0
                    [target-vid vid]
                    [target-did did]
                    [target-version (engine-doc-version engine did)]
                    [prefix prefix]
                    [candidates local]
                    [index 0]
                    [open? (pair? local)]
                    [request-id #f]
                    [timer-id #f]
                    [anchor-line (engine-view-point-line engine vid)]
                    [anchor-col (engine-view-point-column engine vid)]
                    [popup-rect #f]))
     (define state1 (set-completion-state state c1))
     (define state2
       (if (pair? local)
           (docs-show-name! ed state1 (car local))
           state1))
     (define-values (state3 job)
       (editor-state-submit-job state2 'completion
                                (list prefix (resource-path-for-state state2 vid)
                                      (engine-doc-text engine did))
                                (list 'completion (engine-doc-version engine did))))
     (set-completion-state state3
                           (struct-copy completion-state (completion-state-of state3)
                                        [request-id (job-id job)]))]))

(define (handle-timer ed state ev)
  (define c (completion-state-of state))
  (cond
    [(not c) state]
    [(not (equal? (timer-event-id ev) (completion-state-timer-id c))) state]
    [else
     (define state1 (set-completion-state state (struct-copy completion-state c [timer-id #f])))
     (cond
       [(editor-input-active? state1) state1]
       [(editor-placement-active? state1) state1]
       [else
        (define-values (vid did) (current-target ed state1))
        (cond
          [(not vid) (close-completion state1)]
          [else (open-completion! ed state1 vid did)])])]))

;;; ════════════════ changes hook ════════════════

(define (handle-changes ctx ps)
  (define ed (change-context-editor ctx))
  (define engine (change-context-engine ctx))
  (define state (change-context-state ctx))
  (define did (change-context-doc-id ctx))
  (define version (change-context-version ctx))
  (cond
    [(not (completion-state? ps)) (values ctx ps '() #t)]
    [(completion-state-suppress-next? ps)
     (values ctx (struct-copy completion-state ps [suppress-next? #f]) '() #t)]
    [else
     (define fvid (editor-focus-view-id state))
     (define fdid (and fvid (engine-view-doc-id engine fvid)))
     (cond
       [(or (not fvid) (not (equal? did fdid))) (values ctx ps '() #t)]
       [else
        (define ps1
          (cond
            [(completion-state-open? ps)
             (struct-copy completion-state ps
                          [target-version version]
                          [anchor-line (engine-view-point-line engine
                                                              (completion-state-target-vid ps))]
                          [anchor-col (engine-view-point-column engine
                                                             (completion-state-target-vid ps))])]
            [else
             (struct-copy completion-state ps
                          [target-vid fvid]
                          [target-did did]
                          [target-version version]
                          [anchor-line (engine-view-point-line engine fvid)]
                          [anchor-col (engine-view-point-column engine fvid)])]))
        (define ps2
          (cond
            [(not (eq? (editor-state-doc-mode state did) 'racket)) ps1]
            [else
             (editor-cancel-timer! ed (completion-state-timer-id ps1))
             (define tid (editor-schedule-timer! ed 180))
             (struct-copy completion-state ps1 [timer-id tid])]))
        (values ctx ps2 '() #t)])]))

;;; ════════════════ job result ════════════════

(define (handle-job ed state ev)
  (define c (completion-state-of state))
  (cond
    [(not (eq? (job-result-event-kind ev) 'completion)) state]
    [(not c) state]
    [(not (equal? (completion-state-request-id c) (job-result-event-id ev))) state]
    [else
     (define result (job-result-event-result ev))
     (cond
       [(job-error? result)
        (set-completion-state state (struct-copy completion-state c [request-id #f]))]
       [(and (list? result) (andmap string? result))
        (cond
          [(null? result)
           (close-completion (set-completion-state state
                                                   (struct-copy completion-state c [request-id #f])))]
          [else
           (define idx (min (completion-state-index c) (sub1 (length result))))
           (define state1
             (set-completion-state state
                                   (struct-copy completion-state c
                                                [candidates result]
                                                [index idx]
                                                [open? #t]
                                                [request-id #f])))
           (docs-show-name! ed state1 (list-ref result idx))])]
       [else (set-completion-state state (struct-copy completion-state c [request-id #f]))])]))

;;; ════════════════ 命令 ════════════════

(define (move-selection ed state step)
  (define c (completion-state-of state))
  (cond
    [(or (not c) (not (completion-state-open? c))
         (null? (completion-state-candidates c)))
     (values state '())]
    [else
     (define n (length (completion-state-candidates c)))
     (define idx (modulo (+ (completion-state-index c) step) n))
     (define state1 (set-completion-state state
                                          (struct-copy completion-state c [index idx])))
     (values (docs-show-name! ed state1 (list-ref (completion-state-candidates c) idx))
             '())]))

(define (next-command ed state) (move-selection ed state 1))
(define (prev-command ed state) (move-selection ed state -1))

(define (accept-command ed state)
  (define c (completion-state-of state))
  (cond
    [(or (not c) (not (completion-state-open? c))
         (null? (completion-state-candidates c)))
     (values state '())]
    [else
     (define idx (min (completion-state-index c) (sub1 (length (completion-state-candidates c)))))
     (define cand (list-ref (completion-state-candidates c) idx))
     (define ins (completion-insert-text cand (completion-state-prefix c)))
     (define state1
       (set-completion-state state
                             (struct-copy completion-state c
                                          [open? #f]
                                          [candidates '()]
                                          [index 0]
                                          [request-id #f]
                                          [suppress-next? #t]
                                          [popup-rect #f])))
     (if (zero? (string-length ins))
         (values state1 '())
         (editor-insert! ed state1 (completion-state-target-vid c) ins))]))

(define (cancel-command ed state)
  (values (close-completion state) '()))

(define (manual-open-command ed state)
  (define-values (vid did) (current-target ed state))
  (cond
    [(not vid) (values (editor-state-with-flash state "completion: focus is not Racket editor") '())]
    [else (values (open-completion! ed state vid did) '())]))

;;; ════════════════ overlay / sync ════════════════

(define (fit-line s width)
  (define w (max 0 width))
  (cond
    [(<= (string-length s) w) (string-append s (make-string (- w (string-length s)) #\space))]
    [else (substring s 0 w)]))

(define (popup-geometry ed state c)
  (define engine (editor-engine ed))
  (define content (editor-focus-content-rect state))
  (define vid (completion-state-target-vid c))
  (define cur (and content vid (engine-view-cursor-screen-position engine vid)))
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

(define (sync-completion-view! ed state)
  (define c (completion-state-of state))
  (cond
    [(or (not c) (not (completion-state-open? c))
         (null? (completion-state-candidates c)))
     (if (and c (completion-state-popup-rect c))
         (set-completion-state state (struct-copy completion-state c [popup-rect #f]))
         state)]
    [else
     (define g (popup-geometry ed state c))
     (cond
       [(not g)
        (set-completion-state state (struct-copy completion-state c [popup-rect #f]))]
       [else
        (define r (car g))
        (define inner-w (cdr g))
        (define lines (for/list ([x (in-list (completion-state-candidates c))])
                        (fit-line x inner-w)))
        (define idx (min (completion-state-index c) (sub1 (length lines))))
        (define faces (for/list ([i (in-range (length lines))])
                        (if (= i idx) 'completion-selected 'completion)))
        (engine-set-view-content! (editor-engine ed) (completion-state-view-id c)
                                 lines faces)
        (engine-set-view-cursor! (editor-engine ed) (completion-state-view-id c)
                                 idx #:column 0)
        (set-completion-state state
                              (struct-copy completion-state c
                                           [popup-rect r]
                                           [inner-width inner-w]))])]))

(define (sync-completion! ed state)
  (define c (completion-state-of state))
  (cond
    [(or (not c) (not (completion-state-open? c))) state]
    [else
     (define engine (editor-engine ed))
     (define vid (completion-state-target-vid c))
     (define did (completion-state-target-did c))
     (define version (and did (engine-doc-version engine did)))
     (define line (and vid (engine-view-point-line engine vid)))
     (define col (and vid (engine-view-point-column engine vid)))
     (cond
       [(or (not vid) (not version) (not line) (not col))
        (close-completion state)]
       [(not (equal? version (completion-state-target-version c)))
        (close-completion state)]
       [(and (= line (completion-state-anchor-line c))
             (= col (completion-state-anchor-col c)))
        (sync-completion-view! ed state)]
       [else (close-completion state)])]))

(define (completion-overlays ed state)
  (define c (completion-state-of state))
  (cond
    [(and c (completion-state-open? c) (completion-state-popup-rect c))
     (list (make-editor-overlay (completion-state-view-id c)
                                (completion-state-popup-rect c)
                                #:face 'float-border
                                #:deep 100
                                #:weight 100))]
    [else '()]))

(define (service-completion payload)
  (match-define (list prefix path text) payload)
  (define ctx (and text (make-completion-context path text)))
  (and ctx (completion-candidates ctx prefix)))

(define (make-completion-plugin #:view vid)
  (make-plugin
   #:id 'completion
   #:state (empty-completion-state vid)
   #:hooks
   (list
    (make-hook #:owner 'completion
               #:id 'changes
               #:operation 'changes
               #:phase 'observe
               #:fn handle-changes))
   #:sync (λ (ed state)
            (sync-completion! ed (sync-completion-view! ed state)))
   #:services (list (service 'completion service-completion))
   #:handle-job handle-job
   #:handle-timer handle-timer
   #:overlays completion-overlays
   #:commands
   (keys
    [(key 'o 'ctrl) manual-open-command]
    [(key 'up) (make-guarded-command
                #:when (λ (ed state) (completion-focused? state (completion-state-of state)))
                #:run prev-command)]
    [(key 'down) (make-guarded-command
                  #:when (λ (ed state) (completion-focused? state (completion-state-of state)))
                  #:run next-command)]
    [(key 'tab) (make-guarded-command
                 #:when (λ (ed state) (completion-focused? state (completion-state-of state)))
                 #:run next-command)]
    [(key 'enter) (make-guarded-command
                   #:when (λ (ed state) (completion-focused? state (completion-state-of state)))
                   #:run accept-command)]
    [(key 'escape) (make-guarded-command
                    #:when (λ (ed state) (completion-focused? state (completion-state-of state)))
                    #:run cancel-command)]
    [(key 'g 'ctrl) (make-guarded-command
                     #:when (λ (ed state) (completion-focused? state (completion-state-of state)))
                     #:run cancel-command)])))

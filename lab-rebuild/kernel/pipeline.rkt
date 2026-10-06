#lang racket

;;; lab-rebuild/kernel/pipeline.rkt —— 事件 → 动作 → 效果 → 会话（kernel 唯一写入点）。
;;;
;;; step:
;;;   1 resolve（层栈 + base，capture 短路 + 字符回退）
;;;   2 perform（before-policy 门控 → 命令 → after-policy 变换）
;;;   3 handle-effects（apply-effect 逐个施加；notify/job/resume 递归）
;;;   4 post：声明式 pop + on-blur + post-command
;;;
;;; 任何命令 / 钩子 / 插件都不直接改 session —— 只产 Effect，由这里施加。

(require racket/file
         racket/path
         "editor-api.rkt"
         "action.rkt" "effect.rkt" "policy.rkt" "layer.rkt"
         "session.rkt" "runtime.rkt" "registry.rkt" "table.rkt"
         "frame.rkt" "focus.rkt" "paths.rkt" "binding.rkt" "panel.rkt" "hooks.rkt" "command.rkt")

(provide step resolve run-notify apply-effects! effective-slot-vid
         pipeline-pending! pipeline-deliver!)

;;; ================= 工具 =================

(define (sess ctx) (ctx-session ctx))
(define (update ctx f) (ctx-with-session ctx (f (ctx-session ctx))))
(define (set-editor ctx ed) (update ctx (λ (s) (struct-copy session s [editor ed]))))
(define (basename p)
  (path->string (or (file-name-from-path (path->complete-path p)) p)))

;; 底部槽位的有效视图：栈顶声明 slot='input' 的层 → input 视图，否则 status 视图。
(define (effective-slot-vid ctx)
  (define s (sess ctx))
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define (wants-input? i)
    (define c (reg-ref reg 'layer-spec (layer-inst-spec-id i)))
    (define spec (and c (contrib-value c)))
    (and spec (eq? (layer-spec-slot spec) 'input)))
  (or (for/first ([i (in-list (input-instances (session-input s)))]
                  #:when (wants-input? i))
        (session-input-vid s))
      (session-status-vid s)))

;;; ================= resolve =================

(define (resolve ctx ev)
  (define s (sess ctx))
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define focus-vid (session-focus-vid s))
  (define did (and focus-vid (editor-view-document-id (session-editor s) focus-vid)))
  (define base (if did (command-set-tables (session-cs s) did) (command-set-global (session-cs s))))
  (define b (event->binding ev))
  (define (lookup tables)
    (and b (or (keytable-lookup tables b) (table-char-lookup tables ev))))
  (let loop ([insts (input-instances (session-input s))] [collected '()])
    (cond
      [(null? insts) (values (lookup (append base collected)) #f)]
      [else
       (define inst (car insts))
       (define spec (let ([c (reg-ref reg 'layer-spec (layer-inst-spec-id inst))])
                      (and c (contrib-value c))))
       (cond
         [(not spec) (loop (cdr insts) collected)]
         [else
          (define ts ((layer-spec-tables spec) ctx inst))
          (define collected* (append ts collected))   ; 底在前、顶在后
          (cond
            [(eq? (layer-spec-capture spec) 'all)
             (values (lookup collected*) (layer-inst-spec-id inst))]
            [else (loop (cdr insts) collected*)])])])))

;;; ================= perform =================

(define (invoke-action ctx action)
  (define s (action-source action))
  (case (car s)
    [(command) (invoke-command ctx (car (action-payload action)) (cadr (action-payload action)))]
    [(hook)    (run-hooks ctx (cadr s) (action-payload action))]
    [else '()]))

(define (perform ctx action owner)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define before (for/list ([c (in-list (reg-kind reg 'policy))]
                            #:when (eq? (policy-phase (contrib-value c)) 'before))
                   (contrib-value c)))
  (let loop ([ps before])
    (cond
      [(null? ps) (handle-effects ctx action (invoke-action ctx action))]
      [else
       (define p (car ps))
       (cond
         [((policy-match? p) ctx action)
          (define dec ((policy-decide p) ctx action))
          (cond
            [(eq? dec 'pass) (loop (cdr ps))]
            [(eq? dec 'abort) ctx]
            [(interaction? dec) (start-interaction ctx action dec)]
            [(list? dec) (handle-effects ctx action dec)]
            [else (loop (cdr ps))])]
         [else (loop (cdr ps))])])))

(define (handle-effects ctx action effs)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define after (for/list ([c (in-list (reg-kind reg 'policy))]
                           #:when (eq? (policy-phase (contrib-value c)) 'after))
                  (contrib-value c)))
  (define effs* (for/fold ([es effs]) ([p (in-list after)])
                  (if ((policy-match? p) ctx action) ((policy-decide p) ctx action es) es)))
  (for/fold ([c ctx]) ([e (in-list effs*)]) (apply-effect c e)))

;; 供 app / 测试：把一串 effect 走完整管线（after-policy + 施加）。
(define (apply-effects! ctx effs)
  (handle-effects ctx (action 'api #f) effs))

;;; ================= 异步版本闸门（内核统一） =================
;;; 传输（sync/place、影子状态）由特性自管；闸门只写一遍。

(define (pipeline-pending! ctx id version current? on-result)
  (update ctx (λ (s) (struct-copy session s
                       [awaiting (hash-set (session-awaiting s) id
                                           (list version current? on-result))]))))

;; 结果到达：命中且版本仍当前 → 施加 on-result 的 effect（过 after-policy）。
(define (pipeline-deliver! ctx id result)
  (define s (sess ctx))
  (define e (hash-ref (session-awaiting s) id #f))
  (cond
    [(not e) ctx]
    [else
     (define version (car e))
     (define cur? (cadr e))
     (define on-result (caddr e))
     (define ctx1 (update ctx (λ (s) (struct-copy session s
                                        [awaiting (hash-remove (session-awaiting s) id)]))))
     (cond
       [(cur? ctx1 version)
        (handle-effects ctx1 (action (list 'job-result id) result) (on-result ctx1 result))]
       [else ctx1])]))

;;; ================= interaction =================

(define (start-interaction ctx action it)
  (define s (sess ctx))
  (define sid (session-next-sid s))
  (define ctx1 (update ctx (λ (s) (struct-copy session s
                                     [next-sid (add1 sid)]
                                     [interactions (cons (suspension-new sid (interaction-resume it))
                                                         (session-interactions s))]))))
  (handle-effects ctx1 action ((interaction-start it) ctx1 sid)))

;; 挂起在 resume 后**不自动移除**：交互可多步（如逐个问保存），每步用同一 sid 再 resume。
;; 结束由交互自己发 `e-interaction-end`（见 end-interaction），否则登记会残留。
(define (resume-interaction ctx sid response)
  (define s (sess ctx))
  (define sus (for/first ([x (in-list (session-interactions s))] #:when (= sid (suspension-id x))) x))
  (cond
    [(not sus) ctx]
    [else (handle-effects ctx (action (list 'resume sid) response)
                          ((suspension-resume sus) ctx sid response))]))

(define (end-interaction ctx sid)
  (update ctx (λ (s) (struct-copy session s
                        [interactions (for/list ([x (in-list (session-interactions s))]
                                                 #:unless (= sid (suspension-id x)))
                                        x)]))))

;;; ================= notify =================

(define max-notify-depth 16)
(define current-notify-depth (make-parameter 0))

(define (run-notify ctx hook hargs)
  (cond
    [(>= (current-notify-depth) max-notify-depth) ctx]   ; 重入预算：安全底线
    [else
     (parameterize ([current-notify-depth (add1 (current-notify-depth))])
       (handle-effects ctx (action (list 'hook hook) hargs) (run-hooks ctx hook hargs)))]))

(define (edit-notify ctx vid changes typing?)
  (cond
    [(null? changes) ctx]
    [else
     (define ctx1 (run-notify ctx 'after-edit (list vid changes)))
     (if typing? (run-notify ctx1 'after-insert (list vid changes)) ctx1)]))

;;; ================= apply-effect =================

(define (apply-effect ctx e)
  (define tag (effect-tag e))
  (define args (effect-args e))
  ;; 功能可注册 effect 处理器（contrib 'effect tag handler，handler : Ctx . args -> Ctx）；
  ;; 未注册则走内建框架 effect。施加入口仍唯一。
  (define h (reg-ref (runtime-registry (ctx-runtime ctx)) 'effect tag))
  (cond
    [h (apply (contrib-value h) ctx args)]
    [else (apply-builtin-effect ctx tag args)]))

(define (apply-builtin-effect ctx tag args)
  (case tag
    [(session-size)
     (define w (list-ref args 0)) (define h (list-ref args 1))
     (update ctx (λ (s) (struct-copy session s [width (max 20 w)] [height (max 5 h)])))]

    [(type)
     (match-define (list vid text mt typing?) args)
     (define ed (session-editor (sess ctx)))
     (define-values (changes _ok?) (editor-view-insert! ed vid text mt))
     (edit-notify ctx vid changes typing?)]
    [(backspace)
     (match-define (list vid mt) args)
     (define ed (session-editor (sess ctx)))
     (define-values (changes _ok?) (editor-view-backspace! ed vid mt))
     (edit-notify ctx vid changes #t)]
    [(delete)
     (match-define (list vid mt) args)
     (define ed (session-editor (sess ctx)))
     (define-values (changes _ok?) (editor-view-delete! ed vid mt))
     (edit-notify ctx vid changes #t)]
    [(nav)
     (match-define (list vid dir extend?) args)
     (define ed (session-editor (sess ctx)))
     (case dir
       [(left)  (editor-view-left! ed vid extend?)]
       [(right) (editor-view-right! ed vid extend?)]
       [(up)    (editor-view-up! ed vid extend?)]
       [(down)  (editor-view-down! ed vid extend?)]
       [(home)  (editor-view-home! ed vid extend?)]
       [(end)   (editor-view-end! ed vid extend?)])
     (run-notify ctx 'after-nav '())]
    [(undo) (editor-view-undo! (session-editor (sess ctx)) (car args)) ctx]
    [(redo) (editor-view-redo! (session-editor (sess ctx)) (car args)) ctx]
    [(select-all) (editor-view-select-all! (session-editor (sess ctx)) (car args)) ctx]
    [(copy) (editor-view-copy! (session-editor (sess ctx)) (car args)) ctx]
    [(cut)
     (define vid (car args))
     (define-values (changes _ok?) (editor-view-cut! (session-editor (sess ctx)) vid))
     (edit-notify ctx vid changes #t)]
    [(paste)
     (define vid (car args))
     (define-values (changes _ok?) (editor-view-paste! (session-editor (sess ctx)) vid))
     (edit-notify ctx vid changes #t)]
    [(move) (editor-view-set-selections! (session-editor (sess ctx)) (car args) (cadr args)) ctx]
    [(reload) (editor-view-assign! (session-editor (sess ctx)) (car args) (cadr args)) ctx]

    [(show)
     (match-define (list id placement focus?) args)
     (cond
       ;; path 对象或字符串均可（文件树传 path，find-file 传 string）
       [(or (string? id) (path? id))
        (define-values (ctx1 did) (let-values ([(ed2 did) (open-into ctx id)])
                                    (values (set-editor ctx ed2) did)))
        (show-document ctx1 did focus? placement)]
       [(number? id) (show-document ctx id focus? placement)]
       [else ctx])]

    [(show-view)
     (match-define (list vid focus? placement) args)
     (define s0 (sess ctx))
     (define fr (place-view (session-frame s0) (session-edit-vid s0) vid placement))
     (define ctx1 (update ctx (λ (s) (struct-copy session s [frame fr]))))
     (if focus?
         (update ctx1 (λ (s) (struct-copy session s [focus (focus-set (session-focus s) vid)])))
         ctx1)]

    [(view-new)
     (define did (car args))
     (define s (sess ctx))
     (define-values (ed2 _v) (editor-add-view (session-editor s) did
                                              (session-width s) (max 1 (sub1 (session-height s)))
                                              #:line-numbers? #t))
     (set-editor ctx ed2)]

    [(view-close)
     (define vid (car args))
     (define s (sess ctx))
     (define ed2 (editor-close-view (session-editor s) vid))
     (define fr (frame-remove (session-frame s) vid))
     (define leaves (frame-leaves fr))
     (define next (if (pair? leaves) (leaf-vid (car leaves)) #f))
     (define ctx1 (set-editor (update ctx (λ (s) (struct-copy session s [frame fr]))) ed2))
     (if (eqv? vid (session-focus-vid (sess ctx1)))
         (update ctx1 (λ (s) (struct-copy session s [focus (focus-set (session-focus s) next)])))
         ctx1)]

    [(save)
     (define did (car args))
     (define p (path-table-path (session-paths (sess ctx)) did))
     (when p
       (call-with-output-file p #:exists 'replace
         (λ (out) (display (editor-document-string (session-editor (sess ctx)) did) out))))
     ctx]

    [(close)
     (define ids (car args))
     (define s (sess ctx))
     (define dids (filter number? ids))
     (define ed2 (for/fold ([ed (session-editor s)]) ([d (in-list dids)]) (editor-close-document ed d)))
     (for ([d (in-list dids)]) (path-table-remove! (session-paths s) d))
     (define fr (for/fold ([fr (session-frame s)]) ([v (in-list (frame-leaves (session-frame s)))])
                  (if (memv (leaf-vid v) ids) (frame-remove fr (leaf-vid v)) fr)))
     (define ctx1 (set-editor ctx ed2))
     (for/fold ([c ctx1]) ([d (in-list dids)]) (run-notify c 'document-closed (list d)))]

    [(focus)
     (define target (car args))
     (update ctx (λ (s)
                   (cond
                     [(eq? target 'restore) (struct-copy session s [focus (focus-restore (session-focus s))])]
                     [(and (pair? target) (eq? (car target) 'dir))
                      (define nv (pane-dir s (cadr target)))
                      (if nv (struct-copy session s [focus (focus-set (session-focus s) nv)]) s)]
                     [(number? target) (struct-copy session s [focus (focus-set (session-focus s) target)])]
                     [else s])))]

    [(focus-push)
     (define target (car args))
     (update ctx (λ (s) (struct-copy session s [focus (focus-push (session-focus s) target)])))]

    [(sidebar) (update ctx (λ (s) (struct-copy session s [sidebar? (car args)])))]

    [(active-panel) (update ctx (λ (s) (struct-copy session s [active-panel (car args)])))]

    [(input)
     (define op (car args))
     (case (car op)
       [(push) (input-push-apply ctx (cadr op) (caddr op))]
       [(pop)  (input-pop-apply ctx (cadr op))]
       [(set)  (update ctx (λ (s) (struct-copy session s [input (input-replace (session-input s) (cadr op) (caddr op))])))]
       [else ctx])]

    [(resume) (resume-interaction ctx (car args) (cadr args))]
    [(interaction-end) (end-interaction ctx (car args))]

    [(await)
     (match-define (list id version current? on-result) args)
     (pipeline-pending! ctx id version current? on-result)]

    [(deliver)
     (pipeline-deliver! ctx (car args) (cadr args))]

    [(notify) (run-notify ctx (car args) (cadr args))]

    [(quit) (update ctx (λ (s) (struct-copy session s [quit? #t])))]

    [(split) (do-split ctx (car args))]

    [(pane-close) (do-pane-close ctx)]

    [(pane-swap)
     (define dir (car args))
     (define s (sess ctx))
     (define v1 (session-focus-vid s))
     (define v2 (pane-dir s dir))
     (cond
       [(and v1 v2)
        (update ctx (λ (s) (struct-copy session s [frame (frame-swap (session-frame s) v1 v2)])))]
       [else ctx])]

    [(pane-resize)
     (define dir (car args))
     (define s (sess ctx))
     (define v (session-focus-vid s))
     (cond
       [(not v) ctx]
       [else
        (define p (and (session-sidebar? s) (shown-panel (session-panels s) (session-active-panel s))))
        (define-values (_sw main)
          (workspace-main-area (session-width s) (session-height s)
                               (and p #t) (session-sidebar-width s)))
        (define axis (if (memq dir '(left right)) 'width 'height))
        (define delta (if (memq dir '(right down)) 1 -1))
        (update ctx (λ (s) (struct-copy session s
                              [frame (frame-resize (session-frame s) v axis delta main)])))])]

    [else ctx]))

;;; ================= 工作区操作 =================

(define (do-split ctx dir)
  (define s (sess ctx))
  (define vid (session-edit-vid s))
  (cond
    [(not vid) ctx]
    [else
     (define did (editor-view-document-id (session-editor s) vid))
     (define-values (ed2 v2)
       (editor-add-view (session-editor s) did
                        (session-width s) (max 1 (sub1 (session-height s)))
                        #:line-numbers? #t))
     (define fr (frame-split (session-frame s) vid dir v2))
     (define ctx1 (set-editor (update ctx (lambda (s) (struct-copy session s [frame fr]))) ed2))
     (update ctx1 (lambda (s) (struct-copy session s [focus (focus-set (session-focus s) v2)])))]))

(define (do-pane-close ctx)
  (define s (sess ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not vid) ctx]
    [else
     (define fr (frame-remove (session-frame s) vid))
     (define leaves (frame-leaves fr))
     (define next (if (pair? leaves) (leaf-vid (car leaves)) #f))
     (update ctx (lambda (s) (struct-copy session s
                                          [frame fr]
                                          [focus (focus-set (session-focus s) next)])))]))


;;; ================= open / show =================

(define (open-into ctx path)
  (define s (sess ctx))
  (define np (simplify-path (path->complete-path path)))
  (define existing (path-table-did (session-paths s) np))
  (cond
    [existing (values (session-editor s) existing)]
    [else
     (define content (if (file-exists? np) (file->string np) ""))
     (define-values (ed2 did) (editor-add-document (session-editor s) content (basename np)))
     (path-table-add! (session-paths s) did np)
     (values ed2 did)]))

;; 放置：把 vid 放进 active 叶（'replace）/ 在 active 上分屏（(list 'split dir)）；
;; 已在树里则只是聚焦，不重复放置（避免破坏分屏）。
(define (place-view fr active vid placement)
  (cond
    [(frame-contains? fr vid) fr]
    [(not (frame-root fr)) (frame-set-root fr (leaf vid 'edit))]
    [(and active (frame-contains? fr active))
     (if (and (pair? placement) (eq? (car placement) 'split))
         (frame-split fr active (cadr placement) vid)
         (frame-replace fr active (leaf vid 'edit)))]
    [else (frame-set-root fr (leaf vid 'edit))]))

(define (show-document ctx did focus? [placement 'replace])
  (define s (sess ctx))
  (define ed (session-editor s))
  (define vids (editor-document-view-list ed did))
  (define-values (ctx1 vid)
    (cond
      [(pair? vids) (values ctx (car vids))]
      [else
       (define-values (ed2 vid) (editor-add-view ed did (session-width s)
                                                  (max 1 (sub1 (session-height s)))
                                                  #:line-numbers? #t))
       (values (set-editor ctx ed2) vid)]))
  (define s1 (sess ctx1))
  (define fr (place-view (session-frame s1) (session-edit-vid s1) vid placement))
  (define ctx2 (update ctx1 (λ (s) (struct-copy session s [frame fr]))))
  (define ctx3 (run-notify ctx2 'document-opened (list did)))
  (if focus?
      (update ctx3 (λ (s) (struct-copy session s [focus (focus-set (session-focus s) vid)])))
      ctx3))

;;; ================= focus 几何 =================

(define (focus-rects s)
  (define w (session-width s))
  (define h (session-height s))
  (define p (and (session-sidebar? s) (shown-panel (session-panels s) (session-active-panel s))))
  (define-values (sw main) (workspace-main-area w h (and p #t) (session-sidebar-width s)))
  (define-values (rects _) (frame->rectangles (session-frame s) main))
  (define base (for/list ([r (in-list rects)]) (cons (rectangle-view-id r) r)))
  (if p
      (cons (cons (panel-vid p) (rectangle (panel-vid p) 0 0 sw h 0)) base)
      base))

(define (pane-dir s dir)
  (define all (focus-rects s))
  (define cur (session-focus-vid s))
  (cond
    [(or (not cur) (null? (cdr all))) #f]
    [else
     (define c (for/first ([p (in-list all)] #:when (eqv? (car p) cur)) (cdr p)))
     (cond
       [(not c) #f]
       [else
        (define cx (+ (rectangle-x c) (quotient (rectangle-width c) 2)))
        (define cy (+ (rectangle-y c) (quotient (rectangle-height c) 2)))
        (define best
          (for/fold ([best #f]) ([p (in-list all)] #:unless (eqv? (car p) cur))
            (define r (cdr p))
            (define rx (+ (rectangle-x r) (quotient (rectangle-width r) 2)))
            (define ry (+ (rectangle-y r) (quotient (rectangle-height r) 2)))
            (define ok (case dir
                         [(left)  (< rx cx)] [(right) (> rx cx)]
                         [(up)    (< ry cy)] [(down)  (> ry cy)]
                         [else #f]))
            (if (not ok)
                best
                (let ([d (+ (abs (- rx cx)) (abs (- ry cy)))])
                  (if (or (not best) (< d (car best))) (cons d (car p)) best)))))
        (and best (cdr best))])]))

;;; ================= 层入栈 / 出栈 =================

(define (input-push-apply ctx spec-id state)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define spec (let ([c (reg-ref reg 'layer-spec spec-id)]) (and c (contrib-value c))))
  (unless spec (error 'input-push "未注册的 layer-spec: ~a" spec-id))
  (define inst (layer-inst spec-id state))
  (define ctx1 (update ctx (λ (s) (struct-copy session s [input (input-push (session-input s) spec-id state)]))))
  (define ctx2 (handle-effects ctx1 (action 'layer-enter spec-id) ((layer-spec-on-enter spec) ctx1 inst)))
  (define f (layer-spec-focus spec))
  (cond
    [(and f (eq? f 'input-view))
     (update ctx2 (λ (s) (struct-copy session s [focus (focus-push (session-focus s) (session-input-vid s))])))]
    [else ctx2]))

(define (input-pop-apply ctx spec-id)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define spec (let ([c (reg-ref reg 'layer-spec spec-id)]) (and c (contrib-value c))))
  (define inst (input-find (session-input (sess ctx)) spec-id))
  (define ctx1 (if (and spec inst)
                   (handle-effects ctx (action 'layer-exit spec-id) ((layer-spec-on-exit spec) ctx inst))
                   ctx))
  (update ctx1 (λ (s)
                 (define s* (struct-copy session s [input (input-pop (session-input s) spec-id)]))
                 (if (and spec (layer-spec-focus spec))
                     (struct-copy session s* [focus (focus-restore (session-focus s*))])
                     s*))))

;;; ================= post =================

;; pre-instances = 事件开始前的层快照（新推入的层不在其中 → pop='next' 不会同一事件被弹）。
(define (post-pop ctx owner pre-instances)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define to-drop
    (for/list ([i (in-list pre-instances)]
               #:when (let ([c (reg-ref reg 'layer-spec (layer-inst-spec-id i))])
                        (and c
                             (case (layer-spec-pop (contrib-value c))
                               [(next) #t]
                               [(handled) (eq? owner (layer-inst-spec-id i))]
                               [else #f]))))
      (layer-inst-spec-id i)))
  (for/fold ([c ctx]) ([id (in-list to-drop)]) (input-pop-apply c id)))

(define (post-blur ctx)
  (define reg (runtime-registry (ctx-runtime ctx)))
  (define s (sess ctx))
  (define focus-vid (session-focus-vid s))
  (for/fold ([c ctx]) ([i (in-list (input-instances (session-input s)))])
    (define spec (let ([c (reg-ref reg 'layer-spec (layer-inst-spec-id i))]) (and c (contrib-value c))))
    (cond
      [(and spec (layer-spec-on-blur spec)
            (eq? (layer-spec-focus spec) 'input-view)
            (not (eqv? focus-vid (session-input-vid s))))
       (handle-effects c (action 'layer-blur (layer-inst-spec-id i)) ((layer-spec-on-blur spec) c i))]
      [else c])))

;;; ================= step =================

(define (step ctx ev)
  (define pre-instances (input-instances (session-input (sess ctx))))
  (cond
    [(resize-event? ev)
     (handle-effects ctx (action 'tick #f)
                     (list (e-session-size (resize-event-cols ev) (resize-event-rows ev))))]
    [else
     (define-values (spec owner) (resolve ctx ev))
     (define ctx1 (if spec (perform ctx (make-command-action spec ev) owner) ctx))
     (define ctx2 (post-pop ctx1 owner pre-instances))
     (define ctx3 (post-blur ctx2))
     (run-notify ctx3 'post-command '())]))

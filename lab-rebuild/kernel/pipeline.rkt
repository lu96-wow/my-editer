#lang racket

;;; lab-rebuild/kernel/pipeline.rkt —— 事件 → 命令 → 效果 → 会话（唯一写入点）。
;;;
;;; step:  resolve（事件 → binding → 焦点决定表 → spec） → perform（命令 → effects） → apply。
;;; apply-effect 先查 registry 的 'effect 处理器（特性写入点），否则走内建。
;;;
;;; 本模块不再做文件 I/O / 路径；只做「装文档 / 显示文档」这类 workspace 操作。

(require "editor-api.rkt"
         "effect.rkt" "registry.rkt" "runtime.rkt" "session.rkt" "focus.rkt"
         "frame.rkt" "dock.rkt" "workspace.rkt" "geometry.rkt" "documents.rkt"
         "binding.rkt" "table.rkt" "command.rkt" "hooks.rkt" "layer.rkt"
         "action.rkt" "policy.rkt")

(provide step apply-effect run-notify)

(define (sess ctx) (ctx-session ctx))
(define (update ctx f) (ctx-with-session ctx (f (ctx-session ctx))))

;;; ================= 生命周期通知 =================

(define (run-notify ctx point args)
  (apply-effects ctx (run-hooks ctx point args)))

(define (edit-notify ctx vid changes [typing? #t])
  (cond
    [(null? changes) ctx]
    [else
     (define ctx1 (run-notify ctx 'after-edit (list vid changes)))
     (if typing? (run-notify ctx1 'after-insert (list vid changes)) ctx1)]))

;;; ================= resolve / perform =================

;; 焦点对应的 base 表（dock 或主区编辑）+ global。
(define (base-tables ctx)
  (define s (ctx-session ctx))
  (define fv (session-focus-vid s))
  (define d (and fv
                 (for/first ([d (in-list (workspace-docks (session-workspace s)))]
                             #:when (eqv? fv (dock-vid d)))
                   d)))
  (list (if d (or (dock-keys d) (kbd)) (session-keys s))
        (session-global s)))

(define (reg-layer ctx spec-id)
  (define c (reg-ref (runtime-registry (ctx-runtime ctx)) 'layer-spec spec-id))
  (and c (contrib-value c)))

;; 层栈解析：表顺序 = base → 底层 → … → 栈顶（后者覆盖前者）。
;; 返回 (values spec owner)：owner = 捕获本事件的 spec-id（否则 #f）。
(define (resolve ctx ev)
  (define b (event->binding ev))
  (define (lookup tables) (and b (keytable-lookup (keytable-merge tables) b)))
  (let loop ([insts (layer-stack-instances (session-input (ctx-session ctx)))]
             [collected '()])
    (cond
      [(null? insts)
       (values (lookup (append (base-tables ctx) collected)) #f)]
      [else
       (define inst (car insts))
       (define spec (reg-layer ctx (layer-inst-spec-id inst)))
       (cond
         [(not spec) (loop (cdr insts) collected)]
         [else
          (define ts ((layer-spec-tables spec) ctx inst))
          (define collected* (append ts collected))   ; 上层的表在后（覆盖）
          (cond
            [(eq? (layer-spec-capture spec) 'all)
             (values (lookup collected*) (layer-inst-spec-id inst))]
            [else (loop (cdr insts) collected*)])])])))

(define (perform ctx spec ev)
  (define action (make-command-action spec ev))
  (define before (before-decision ctx action))
  (cond
    [(eq? before 'abort) ctx]
    [(list? before) (apply-effects ctx before)]
    [else
     (define effs (invoke-command ctx spec ev))
     (define effs* (for/fold ([es effs]) ([p (in-list (policies ctx 'after))])
                     (if ((policy-match? p) ctx action)
                         ((policy-decide p) ctx action es)
                         es)))
     (apply-effects ctx effs*)]))

;;; ================= 政策 =================

(define (policies ctx phase)
  (for/list ([c (in-list (reg-kind (runtime-registry (ctx-runtime ctx)) 'policy))]
             #:when (eq? (policy-phase (contrib-value c)) phase))
    (contrib-value c)))

;; before：首个非 'pass 的决策定夺；#f = 无人插手。
(define (before-decision ctx action)
  (for/or ([p (in-list (policies ctx 'before))])
    (and ((policy-match? p) ctx action)
         (let ([d ((policy-decide p) ctx action)])
           (and (not (eq? d 'pass)) d)))))

(define (apply-effects ctx effs)
  (for/fold ([c ctx]) ([e (in-list effs)]) (apply-effect c e)))

;;; ================= 异步版本闸门（内核统一） =================
;;; 传输（sync/place、影子状态）由特性自管；闸门只写一遍。

(define (pipeline-pending! ctx id version current? on-result)
  (update ctx (lambda (s)
                (struct-copy session s
                  [awaiting (hash-set (session-awaiting s) id
                                      (list version current? on-result))]))))

;; 结果到达：命中且版本仍当前 → 施加 on-result 的 effect。
(define (pipeline-deliver! ctx id result)
  (define s (ctx-session ctx))
  (define e (hash-ref (session-awaiting s) id #f))
  (cond
    [(not e) ctx]
    [else
     (define version (car e))
     (define cur? (cadr e))
     (define on-result (caddr e))
     (define ctx1 (update ctx (lambda (s)
                                (struct-copy session s
                                  [awaiting (hash-remove (session-awaiting s) id)]))))
     (if (cur? ctx1 version)
         (apply-effects ctx1 (on-result ctx1 result))
         ctx1)]))

(define (step ctx ev)
  (define pre (layer-stack-instances (session-input (ctx-session ctx))))
  (cond
    [(resize-event? ev)
     (apply-effect ctx (e-session-size (resize-event-cols ev) (resize-event-rows ev)))]
    [else
     (define-values (spec owner) (resolve ctx ev))
     (define ctx1 (if spec (perform ctx spec ev) ctx))
     (define ctx2 (post-pop ctx1 owner pre))
     (post-blur ctx2)]))

;;; ================= 输入层入栈 / 出栈 =================

(define (layer-push-apply ctx spec-id state)
  (define spec (reg-layer ctx spec-id))
  (unless spec (error 'layer-push "未注册的 layer-spec: ~a" spec-id))
  (define inst (layer-inst spec-id state))
  (define ctx1 (update ctx (lambda (s)
                            (struct-copy session s
                              [input (stack-push (session-input s) spec-id state)]))))
  (define ctx2 (for/fold ([c ctx1]) ([e (in-list ((layer-spec-on-enter spec) ctx1 inst))])
                 (apply-effect c e)))
  (define f (layer-spec-focus spec))
  (cond
    [f
     (if (equal? f (session-focus-vid (ctx-session ctx2)))
         ctx2
         (apply-effect ctx2 (e-focus-push f)))]
    [else ctx2]))

(define (layer-pop-apply ctx spec-id)
  (define spec (reg-layer ctx spec-id))
  (define inst (stack-find (session-input (ctx-session ctx)) spec-id))
  (define ctx1 (if (and spec inst)
                   (for/fold ([c ctx]) ([e (in-list ((layer-spec-on-exit spec) ctx inst))])
                     (apply-effect c e))
                   ctx))
  (update ctx1 (lambda (s)
                 (define s* (struct-copy session s
                              [input (stack-pop (session-input s) spec-id)]))
                 (if (and spec (layer-spec-focus spec))
                     (struct-copy session s* [focus (focus-restore (session-focus s*))])
                     s*))))

(define (layer-set-apply ctx spec-id state)
  (update ctx (lambda (s)
                (struct-copy session s
                  [input (stack-set (session-input s) spec-id state)]))))

(define (layer-pop-until-apply ctx spec-id)
  (update ctx (lambda (s)
                (struct-copy session s
                  [input (stack-pop-until (session-input s) spec-id)]))))

;; 事件结束后：声明式出栈（pop='next' 或 pop='handled' 且本层捕获）。
;; 只看 pre（事件开始前的快照）→ 本事件新推入的层不会被同一事件弹掉。
(define (post-pop ctx owner pre)
  (define to-drop
    (for/list ([i (in-list pre)]
               #:when (let ([spec (reg-layer ctx (layer-inst-spec-id i))])
                        (and spec
                             (case (layer-spec-pop spec)
                               [(next) #t]
                               [(handled) (eq? owner (layer-inst-spec-id i))]
                               [else #f]))))
      (layer-inst-spec-id i)))
  (for/fold ([c ctx]) ([id (in-list to-drop)])
    (apply-effect c (e-layer-pop id))))

;; 有 on-blur 且声明了 focus 的层：焦点离开其目标 → 触发 on-blur。
(define (post-blur ctx)
  (define fv (session-focus-vid (ctx-session ctx)))
  (for/fold ([c ctx]) ([i (in-list (layer-stack-instances (session-input (ctx-session ctx))))])
    (define spec (reg-layer c (layer-inst-spec-id i)))
    (cond
      [(and spec (layer-spec-on-blur spec)
            (layer-spec-focus spec)
            (not (equal? fv (layer-spec-focus spec))))
       (for/fold ([c* c]) ([e (in-list ((layer-spec-on-blur spec) c i))])
         (apply-effect c* e))]
      [else c])))

;;; ================= apply-effect =================

(define (apply-effect ctx e)
  (define tag (effect-tag e))
  (define args (effect-args e))
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
     (define-values (changes _ok?) (editor-view-insert! (session-editor (sess ctx)) vid text mt))
     (edit-notify ctx vid changes typing?)]
    [(backspace)
     (match-define (list vid mt) args)
     (define-values (changes _ok?) (editor-view-backspace! (session-editor (sess ctx)) vid mt))
     (edit-notify ctx vid changes)]
    [(delete)
     (match-define (list vid mt) args)
     (define-values (changes _ok?) (editor-view-delete! (session-editor (sess ctx)) vid mt))
     (edit-notify ctx vid changes)]
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
     (edit-notify ctx vid changes)]
    [(paste)
     (define vid (car args))
     (define-values (changes _ok?) (editor-view-paste! (session-editor (sess ctx)) vid))
     (edit-notify ctx vid changes)]
    [(reload)
     (match-define (list vid value) args)
     (editor-view-assign! (session-editor (sess ctx)) vid value)
     ctx]
    [(move)
     (match-define (list vid sels) args)
     (editor-view-set-selections! (session-editor (sess ctx)) vid sels)
     ctx]

    ;; ----- 文档（只装 / 显示；文件 I/O 是特性） -----
    [(doc-add)
     (match-define (list text name placement focus?) args)
     (define s (sess ctx))
     (define-values (ed2 did) (editor-add-document (session-editor s) text name))
     (define ctx1 (ctx-with-session ctx (struct-copy session s [editor ed2])))
     (define-values (ctx2 did*) (show-document ctx1 did placement focus?))
     (run-notify ctx2 'document-opened (list did*))]
    [(doc-show)
     (match-define (list did placement focus?) args)
     (define-values (ctx1 did*) (show-document ctx did placement focus?))
     (run-notify ctx1 'document-opened (list did*))]
    [(show-view)
     (match-define (list vid focus? placement) args)
     (define s (sess ctx))
     (define ws (session-workspace s))
     (define fr (place-view (workspace-main ws) (session-edit-vid s) vid placement))
     (define s1 (struct-copy session s [workspace (struct-copy workspace ws [main fr])]))
     (define s2 (if focus?
                    (sticky-edit (struct-copy session s1 [focus (focus-set (session-focus s1) vid)]))
                    s1))
     (ctx-with-session ctx s2)]

    [(view-new)
     (define did (car args))
     (define s (sess ctx))
     (define-values (ed2 _v) (editor-add-view (session-editor s) did
                                              (session-width s) (max 1 (sub1 (session-height s)))
                                              #:line-numbers? #t))
     (ctx-with-session ctx (struct-copy session s [editor ed2]))]

    [(view-close)
     (define vid (car args))
     (define s (sess ctx))
     (define ed2 (editor-close-view (session-editor s) vid))
     (define ws (session-workspace s))
     (define fr (frame-remove (workspace-main ws) vid))
     (define next (frame-first-vid fr))
     (define s1 (struct-copy session s
                  [editor ed2]
                  [workspace (struct-copy workspace ws [main fr])]))
     (define s2 (if (eqv? vid (session-focus-vid s))
                    (struct-copy session s1 [focus (focus-set (session-focus s1) next)])
                    s1))
     (ctx-with-session ctx (sticky-edit s2))]

    [(close)
     (define dids (car args))
     (define s (sess ctx))
     (define ed0 (session-editor s))
     (define close-vids (append* (for/list ([d (in-list dids)]) (editor-document-view-list ed0 d))))
     (define ed2 (for/fold ([ed ed0]) ([d (in-list dids)]) (editor-close-document ed d)))
     (define ws (session-workspace s))
     (define fr (for/fold ([fr (workspace-main ws)]) ([cv (in-list close-vids)]) (frame-remove fr cv)))
     (define next (frame-first-vid fr))
     (define s1 (struct-copy session s [editor ed2]
                             [workspace (struct-copy workspace ws [main fr])]
                             [focus (focus-set (session-focus s) (or next (session-focus-vid s)))]
                             [edit-vid (if (and next (frame-contains? fr next)) next #f)]))
     (for/fold ([c (ctx-with-session ctx s1)]) ([d (in-list dids)])
       (run-notify c 'document-closed (list d)))]

    ;; ----- 通用 -----
    [(notify) (run-notify ctx (car args) (cadr args))]

    ;; ----- 焦点 -----
    [(focus)
     (update ctx (λ (s) (sticky-edit (struct-copy session s [focus (focus-set (session-focus s) (car args))]))))]
    [(focus-push)
     (update ctx (λ (s) (sticky-edit (struct-copy session s [focus (focus-push (session-focus s) (car args))]))))]
    [(focus-restore)
     (update ctx (λ (s) (sticky-edit (struct-copy session s [focus (focus-restore (session-focus s))]))))]
    [(focus-dir)
     (define vid (pane-dir ctx (car args)))
     (if vid (apply-effect ctx (e-focus vid)) ctx)]

    ;; ----- 主区 -----
    [(split)
     (define dir (car args))
     (define s (sess ctx))
     (define vid (session-focus-vid s))
     (cond
       [(and vid (main-view? s vid))
        (define ed (session-editor s))
        (define did (editor-view-document-id ed vid))
        (define-values (ed2 v2)
          (editor-add-view ed did (session-width s) (max 1 (sub1 (session-height s)))))
        (define ws (session-workspace s))
        (define fr (frame-split (workspace-main ws) vid dir v2))
        (ctx-with-session ctx
          (struct-copy session s
            [editor ed2]
            [workspace (struct-copy workspace ws [main fr])]
            [focus (focus-set (session-focus s) v2)]
            [edit-vid v2]))]
       [else ctx])]
    [(pane-close)
     (define s (sess ctx))
     (define vid (session-focus-vid s))
     (cond
       [(and vid (main-view? s vid))
        (define ws (session-workspace s))
        (define fr (frame-remove (workspace-main ws) vid))
        (define next (frame-first-vid fr))
        (define ed2 (editor-close-view (session-editor s) vid))
        (ctx-with-session ctx
          (struct-copy session s
            [editor ed2]
            [workspace (struct-copy workspace ws [main fr])]
            [focus (focus-set (session-focus s) next)]
            [edit-vid (if (and next (frame-contains? fr next)) next #f)]))]
       [else ctx])]

    [(pane-swap)
     (define dir (car args))
     (define s (sess ctx))
     (define v1 (session-focus-vid s))
     (define v2 (and v1 (pane-dir ctx dir)))
     (cond
       [(and v1 v2)
        (define ws (session-workspace s))
        (update ctx (lambda (s)
                      (struct-copy session s
                        [workspace (struct-copy workspace ws
                                     [main (frame-swap (workspace-main ws) v1 v2)])])))]
       [else ctx])]

    [(pane-resize)
     (define dir (car args))
     (define s (sess ctx))
     (define v (session-focus-vid s))
     (cond
       [(not v) ctx]
       [else
        (define-values (main _docks)
          (workspace-areas (session-workspace s) (session-width s) (session-height s)))
        (define axis (if (memq dir '(left right)) 'width 'height))
        (define delta (if (memq dir '(right down)) 2 -2))
        (define ws (session-workspace s))
        (update ctx (lambda (s)
                      (struct-copy session s
                        [workspace (struct-copy workspace ws
                                     [main (frame-resize (workspace-main ws) v axis delta main)])])))])]

    ;; ----- 停靠区 -----
    [(dock-visible)
     (match-define (list id flag) args)
     (update ctx (λ (s) (struct-copy session s
                           [workspace (workspace-dock-visible (session-workspace s) id flag)])))]
    [(dock-toggle)
     (define id (car args))
     (update ctx (λ (s)
                   (define d (workspace-dock (session-workspace s) id))
                   (if d
                       (struct-copy session s
                         [workspace (workspace-dock-visible (session-workspace s) id
                                                            (not (dock-visible? d)))])
                       s)))]
    [(dock-resize)
     (match-define (list id delta) args)
     (update ctx (λ (s)
                   (define d (workspace-dock (session-workspace s) id))
                   (if d
                       (struct-copy session s
                         [workspace (workspace-dock-size (session-workspace s) id
                                                         (+ (dock-size d) delta))])
                       s)))]
    ;; 同一侧多 dock 轮换：显示下一个、隐藏同侧其它、聚焦它（panel 组的通用机制）。
    [(dock-cycle)
     (define side (car args))
     (update ctx (lambda (s)
                   (define ws (session-workspace s))
                   (define docks (for/list ([d (in-list (workspace-docks ws))]
                                            #:when (eq? (dock-side d) side)) d))
                   (cond
                     [(null? docks) s]
                     [else
                      (define ids (for/list ([d (in-list docks)]) (dock-id d)))
                      (define fv (session-focus-vid s))
                      (define cur (for/first ([d (in-list docks)] #:when (eqv? fv (dock-vid d))) (dock-id d)))
                      (define idx (if cur
                                      (or (for/first ([id (in-list ids)] [i (in-naturals)]
                                                      #:when (eq? id cur)) i) -1)
                                      -1))
                      (define next (list-ref ids (modulo (add1 idx) (length ids))))
                      (define nd (workspace-dock ws next))
                      (define ws1 (for/fold ([w ws]) ([id (in-list ids)])
                                    (workspace-dock-visible w id (eq? id next))))
                      (struct-copy session s
                        [workspace ws1]
                        [focus (focus-set (session-focus s) (dock-vid nd))])])))]

    ;; ----- 输入层 -----
    [(layer-push) (match-define (list spec-id state) args) (layer-push-apply ctx spec-id state)]
    [(layer-pop) (layer-pop-apply ctx (car args))]
    [(layer-set) (match-define (list spec-id state) args) (layer-set-apply ctx spec-id state)]
    [(layer-pop-until) (layer-pop-until-apply ctx (car args))]

    ;; ----- 异步 -----
    [(await) (match-define (list id version current? on-result) args)
             (pipeline-pending! ctx id version current? on-result)]
    [(deliver) (pipeline-deliver! ctx (car args) (cadr args))]

    [(quit) (update ctx (λ (s) (struct-copy session s [quit? #t])))]
    [else ctx]))

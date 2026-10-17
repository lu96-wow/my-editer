#lang racket

;;; bootstrap/commands.rkt —— 默认命令（纯 transition 构造器）
;;;
;;; 命令只吃 ctx，返回 transition；需要写 core 的地方发 effect。
;;; 这一块是“可替换的默认值”，不是框架核心：用户/插件可以覆盖同名 command-id。

(provide default-command-table
         split-view-command
         close-view-command
         close-region-command
         focus-move-command)

(require "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../env/command.rkt"
         "../env/environment.rkt"
         "../env/role.rkt"
         "../projection/geometry.rkt"
         "../effects/engine.rkt"
         "../../core/editor/ops.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt"
         "../dispatch/context.rkt"
         (prefix-in app: "../base/event.rkt"))

;;; ════════════════ 小工具 ════════════════

(define (message ctx text)
  (transition-pure
   (state-chrome* (ctx-state ctx) (λ (c) (chrome-set-message c text)))))

(define (view-subject ctx)
  (define s (ctx-subject ctx))
  (and (view-id? s) s))

(define (frame-area state)
  (rect 0 0 (window-cols (state-window state)) (window-rows (state-window state))))

;;; ════════════════ 基础命令 ════════════════

(define (nav-command dir)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (nav-effect vid dir)))
             (message ctx "nav: no view")))))

(define (insert-command text)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (insert-text-effect vid text)))
             (message ctx "insert: no view")))))

(define (edit-command op)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (edit-effect vid op)))
             (message ctx "edit: no view")))))

(define (undo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (undo-effect vid)))
             (message ctx "undo: no view")))))

(define (redo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (redo-effect vid)))
             (message ctx "redo: no view")))))

(define (quit-command)
  (cmd (λ (ctx) (transition-pure (state-mark-quit (ctx-state ctx))))))

;;; ════════════════ 切分 / 关闭 ════════════════

(define (split-view-command dir)
  (cmd (λ (ctx) (split-view ctx dir))))

(define (split-view ctx dir)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define did (and vid (workspace-doc-of-view ws vid)))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (cond
    [(not (and did reg)) (message ctx "split: no view")]
    [(not (role-splittable? (environment-role (ctx-env ctx) role)))
     (message ctx "split: region not splittable")]
    [else
     (define rid (region-key reg))
     (define leaf (tree-find (workspace-layout ws) rid))
     (define borders (if leaf (leaf-borders leaf) leaf-borders-all))
     (transition s
                 (list (open-view-effect did
                                          (λ (s* nvid)
                                            (mount-split s* rid borders nvid dir)))))]))
(define (axis/side dir)
  (case dir
    [(left)  (values 'lr 'before)]
    [(right) (values 'lr 'after)]
    [(up)    (values 'tb 'before)]
    [(down)  (values 'tb 'after)]
    [else (error 'split-view "未知方向：~a" dir)]))

(define (mount-split s source-rid borders nvid dir)
  (define-values (axis side) (axis/side dir))
  (define-values (nrid s1) (state-next-id s 'region))
  (define ws (state-workspace s1))
  (define source-reg (workspace-region ws source-rid))
  (define new-reg (region nrid
                          (list (view-member nvid))
                          nvid
                          (if source-reg (region-role source-reg) 'editor)))
  (define ws* (workspace-add-region ws nrid new-reg))
  (define layout* (tree-split (workspace-layout ws*) source-rid axis nrid
                              #:side side #:borders borders))
  (define s2 (state-set-workspace s1 (struct-copy workspace ws* [layout layout*])))
  (transition-pure (state-set-focus s2 nvid)))

(define (close-view-command)
  (cmd (λ (ctx) (close-view ctx))))

(define (close-view ctx)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define reg (and vid (workspace-view-region ws vid)))
  (define role (and reg (region-role reg)))
  (define policy (if role (role-close-policy (environment-role (ctx-env ctx) role)) 'ignore))
  (cond
    [(not vid) (message ctx "close: no view")]
    [(eq? policy 'ignore) (message ctx "close: region ignores close")]
    [else
     (define source-rid (and reg (region-key reg)))
     (define ws* (workspace-remove-view ws vid))
     ;; 优先同 region 里的其它 view，其次任意剩余 view。
     (define fallback
       (or (and source-rid
                (for/first ([v (in-list (workspace-region-views ws* source-rid))]) v))
           (for/first ([v (in-hash-keys (workspace-views ws*))]) v)))
     (define ws** (workspace-set-focus* ws* fallback #:push? #f))
     (transition (state-set-workspace s ws**)
                 (list (close-view-effect vid)))]))

;;; ════════════════ 新建 view / document ════════════════

(define (region-has-view? reg)
  (for/or ([m (in-list (region-members reg))]) (view-member? m)))

;; 目标 region：当前 view 所在 region；没有 view 时找第一个空的 editor region。
(define (target-region-for-new-view ctx)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define subj (ctx-subject ctx))
  (cond
    [(and (view-id? subj) (workspace-view-region ws subj))]
    [else
     (for/first ([r (in-hash-values (workspace-regions ws))]
                 #:when (and (eq? (region-role r) 'editor)
                             (not (region-has-view? r))))
       r)]))

(define (mount-view-in-region s rid vid)
  (define ws (state-workspace s))
  (define reg (workspace-region ws rid))
  (cond
    [(not reg) (transition-pure s)]
    [else
     (define members
       (if (for/or ([m (in-list (region-members reg))])
             (and (view-member? m) (equal? (member-key m) vid)))
           (region-members reg)
           (append (region-members reg) (list (view-member vid)))))
     (define reg* (struct-copy region reg [members members] [active vid]))
     (define ws* (workspace-add-region ws rid reg*))
     (transition-pure (state-set-focus (state-set-workspace s ws*) vid))]))

(define (new-document-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define target (target-region-for-new-view ctx))
         (cond
           [(not target) (message ctx "new: no editor region")]
           [else
            (transition
             s
             (list (open-doc-effect
                    (make-open-doc-spec "*scratch*" "")
                    (λ (s* _did vid)
                      (mount-view-in-region s* (region-key target) vid)))))]))))

;;; ════════════════ 关闭 region / panel ════════════════

(define (subject-region ctx)
  (define subj (ctx-subject ctx))
  (define ws (state-workspace (ctx-state ctx)))
  (cond
    [(view-id? subj) (workspace-view-region ws subj)]
    [(region-id? subj) (workspace-region ws subj)]
    [else #f]))

(define (count-role-regions ws role)
  (for/sum ([r (in-hash-values (workspace-regions ws))]
            #:when (eq? (region-role r) role))
    1))

;; keep-last 的边界：同 role 只剩这一块。
(define (last-region-of-role? ws role)
  (= 1 (count-role-regions ws role)))

;; 去掉 region 里所有 view（不删 region）；返回新 workspace + close-view effects。
(define (drop-region-views ws rid)
  (define vids (workspace-region-views ws rid))
  (values (for/fold ([w ws]) ([vid (in-list vids)])
            (workspace-remove-view w vid))
          (for/list ([vid (in-list vids)]) (close-view-effect vid))))

;; 其它 region 的 active view（排除 rid）；没有 -> #f。
(define (fallback-view ws rid)
  (for/first ([r (in-hash-values (workspace-regions ws))]
              #:unless (equal? (region-key r) rid)
              #:when (view-id? (region-active r)))
    (region-active r)))

(define (close-region-command)
  (cmd (λ (ctx) (close-region ctx))))

(define (close-region ctx)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (subject-region ctx))
  (cond
    [(not reg) (message ctx "close-region: no region")]
    [else
     (define rid (region-key reg))
     (define role (region-role reg))
     (define policy (role-close-policy (environment-role (ctx-env ctx) role)))
     (case policy
       [(ignore)
        (message ctx "close-region: region ignores close")]

       [(hide)
        ;; 只从布局里隐藏；views / region 元数据都保留，之后可 show-region。
        (define ws1 (struct-copy workspace ws
                                 [layout (tree-hide (workspace-layout ws) rid)]))
        (define fb (fallback-view ws1 rid))
        (define ws2 (workspace-set-focus* ws1 fb #:push? #f))
        (transition (state-set-workspace s ws2) '())]

       [(delete)
        (define-values (ws1 evs) (drop-region-views ws rid))
        (define ws2 (workspace-remove-region ws1 rid))
        (define fb (fallback-view ws2 rid))
        (define ws3 (workspace-set-focus* ws2 fb #:push? #f))
        (transition (state-set-workspace s ws3) evs)]

       [(keep-last)
        (if (not (last-region-of-role? ws role))
            ;; 不是最后一块：按 delete 处理
            (let-values ([(ws1 evs) (drop-region-views ws rid)])
              (define ws2 (workspace-remove-region ws1 rid))
              (define fb (fallback-view ws2 rid))
              (define ws3 (workspace-set-focus* ws2 fb #:push? #f))
              (transition (state-set-workspace s ws3) evs))
            ;; 最后一块：清掉 views，但保留空 region 占位
            (let-values ([(ws1 evs) (drop-region-views ws rid)])
              (define fb (fallback-view ws1 rid))
              (define ws2 (workspace-set-focus* ws1 fb #:push? #f))
              (transition (state-set-workspace s ws2) evs)))]

       [else
        (message ctx (format "close-region: unknown policy ~a" policy))])]))

;;; ════════════════ 焦点移动 ════════════════

(define (focus-move-command dir)
  (cmd (λ (ctx) (focus-move ctx dir))))

(define (focus-move ctx dir)
  (define s (ctx-state ctx))
  (define vid (view-subject ctx))
  (define ws (state-workspace s))
  (define reg (and vid (workspace-view-region ws vid)))
  (cond
    [(not reg) (message ctx "focus: no view")]
    [else
     (define-values (rps _cuts)
       (geometry-solve (workspace-layout ws) (frame-area s)))
     ;; 用 region id 当 panel 的 owner，走 core 的方向导航。
     (define panels
       (for/list ([rp (in-list rps)])
         (make-panel (region-panel-region rp)
                     (region-panel-rect rp)
                     (region-panel-borders rp))))
     (define from
       (for/first ([p (in-list panels)]
                   #:when (equal? (panel-view p) (region-key reg)))
         p))
     (define nbr (and from (panel-neighbor panels from dir)))
     (define target-rid (and nbr (panel-view nbr)))
     (define target-reg (and target-rid (workspace-region ws target-rid)))
     (define target-vid (and target-reg (workspace-region-active ws target-rid)))
     (if (view-id? target-vid)
         (transition-pure (state-set-focus s target-vid))
         (message ctx "focus: no neighbor view"))]))

;;; ════════════════ 鼠标：点击落点 / 拖选 ════════════════

;; 屏幕 (row,col) -> 焦点 view 的文档 point。
;; view 的屏幕坐标是「panel 内容区」内的坐标，所以要先减去内容区原点。
(define (screen->point ctx vid row col)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (workspace-view-region ws vid))
  (define eview (ctx-engine ctx))
  (cond
    [(not (and reg eview)) #f]
    [else
     (define area (frame-area s))
     (define-values (rps _cuts) (geometry-solve (workspace-layout ws) area))
     (define rp
       (for/first ([p (in-list rps)]
                   #:when (equal? (region-panel-region p) (region-key reg)))
         p))
     (cond
       [(not rp) #f]
       [else
        (define content (region-panel-content rp))
        (define-values (line c)
          (engine-view-view-screen-position->point
           eview vid
           (- row (rect-y content))
           (- col (rect-x content))))
        (and line (point line c))])]))

(define (pointer-press-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (define ev (ctx-event ctx))
         (if (not (and vid (app:mouse-event? ev)))
             (transition-pure (ctx-state ctx))
             (let ([pt (screen->point ctx vid
                                      (app:mouse-event-row ev)
                                      (app:mouse-event-col ev))])
               (if (not pt)
                   (transition-pure (state-set-focus (ctx-state ctx) vid))
                   (let* ([s1 (state-set-focus (ctx-state ctx) vid)]
                          [s2 (state-input*
                               s1
                               (λ (i)
                                 (input-set-gesture
                                  i (make-gesture 'select vid (list vid pt)))))] )
                     (transition s2
                                 (list (select-effect
                                        vid
                                        (selections-one (caret pt))))))))))))

(define (pointer-drag-command)
  (cmd (λ (ctx)
         (define s (ctx-state ctx))
         (define d (input-gesture (state-input s)))
         (define ev (ctx-event ctx))
         (if (not (and (gesture? d) (eq? (gesture-kind d) 'select)))
             (transition-pure s)
             (let* ([vid (gesture-owner d)]
                    [anchor (cadr (gesture-data d))]
                    [pt (and (app:mouse-event? ev)
                             (screen->point ctx vid
                                            (app:mouse-event-row ev)
                                            (app:mouse-event-col ev)))])
               (if pt
                   (transition s
                               (list (select-effect
                                      vid
                                      (selections-one (selection anchor pt)))))
                   (transition-pure s)))))))

;;; ════════════════ 默认命令表 ════════════════

(define (default-command-table)
  (hash 'quit         (quit-command)
        'nav-left     (nav-command 'left)
        'nav-right    (nav-command 'right)
        'nav-up       (nav-command 'up)
        'nav-down     (nav-command 'down)
        'nav-home     (nav-command 'home)
        'nav-end      (nav-command 'end)
        'insert-enter (insert-command "\n")
        'backspace    (edit-command (op-backspace))
        'delete       (edit-command (op-delete))
        'undo         (undo-command)
        'redo         (redo-command)
        'split-right  (split-view-command 'right)
        'split-down   (split-view-command 'down)
        'close-view   (close-view-command)
        'close-region (close-region-command)
        'new-document (new-document-command)
        'focus-left   (focus-move-command 'left)
        'focus-right  (focus-move-command 'right)
        'focus-up     (focus-move-command 'up)
        'focus-down   (focus-move-command 'down)
        'pointer-press (pointer-press-command)
        'pointer-drag  (pointer-drag-command)))

#lang racket

;;; edit-tui-rebuild/editor/layout.rkt —— 布局操作面
;;;
;;; 布局本身是纯值（core/layout），这里只负责：
;;;   · 把 layout 放进 editor-state
;;;   · split / close / focus 时创建 / 删除 engine view
;;;   · 跑 layout 扩展点
;;;
;;; 插件不直接 require 这个文件；它们通过 editor/api.rkt 拿到
;;; editor-split! / editor-close! / editor-focus! 和 layout-context。
;;;
;;; 当前布局规则刻意很小：
;;;   editor : 可 split / close / focus
;;;   status : 固定 1 行，不可 split / close / focus

(require "../core/api.rkt"
         "../core/layout/api.rkt"
         "../core/projection/api.rkt"
         "../core/focus/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "engine/api.rkt"
         "context.rkt"
         "state.rkt"
         "resource.rkt"
         "hooks.rkt"
         "action.rkt"
         "ops/surface.rkt")

(provide (struct-out layout-context)
         make-layout-context
         editor-layout-panels
         editor-focus-panel-id
         editor-focus-panel
         editor-focus-panel-kind
         editor-focus-view-id
         editor-focus-view
         editor-focus-view-if-attached!
         editor-focus-content-rect
         editor-visible-editor-panels
         editor-split!
         editor-close!
         editor-focus!
         editor-cycle-sidebar-view!
         editor-cycle-editor-view!
         editor-toggle-sidebar!
         editor-toggle-panel!
         editor-mouse!)

;;; ════════════════ 配置 ════════════════


;;; ════════════════ 初始布局 ════════════════


;;; ════════════════ 查询 ════════════════

(define (editor-focus-panel-id state)
  (define l (editor-state-layout state))
  (and l (layout-focus l)))

(define (editor-focus-panel state)
  (define l (editor-state-layout state))
  (and l (layout-panel l (layout-focus l))))

(define (editor-focus-panel-kind state)
  (define p (editor-focus-panel state))
  (and p (p:panel-kind p)))

(define (editor-focus-view-id state)
  (define p (editor-focus-panel state))
  (and p (p:panel-active p)))

;; focus 一个已经挂在 panel 上的 view；detached -> attached? = #f，由调用方 placement。
(define (editor-focus-view-if-attached! ed state vid)
  (define l (editor-state-layout state))
  (define pid (and l vid (layout-panel-for-view l vid)))
  (cond
    [(not pid) (values state '() #f)]
    [else
     (define-values (l* ok?) (layout-panel-set-active-view l pid vid))
     (define l** (if ok? (layout-set-focus l* pid) (layout-set-focus l pid)))
     (values (editor-state-with-layout state l**) '() #t)]))

(define (editor-focus-view ed state)
  (define vid (editor-focus-view-id state))
  (and vid (engine-view-object (editor-engine ed) vid)))

;; focus panel 的内容区 rect（给 completion popup 定位）。
(define (editor-focus-content-rect state)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (define pid (editor-focus-panel-id state))
  (and l area pid (layout-content-rect l area pid)))

;; 可见 editor panel（按树序）。
(define (editor-visible-editor-panels state)
  (define l (editor-state-layout state))
  (and l
       (for/list ([pid (in-list (layout-visible-panel-ids l))]
                  #:when (eq? (p:panel-kind (layout-panel l pid)) 'editor))
         pid)))

;; layout -> repo core panels（给 host 渲染 / 命中用）。
(define (editor-layout-panels ed state)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (and l area
       (layout->render-panels l area
                              #:view-object
                              (λ (vid) (engine-view-object (editor-engine ed) vid))
                              #:focus-panel (layout-focus l))))

;;; ════════════════ layout 扩展点 ════════════════

;; action : 'split | 'close | 'focus
(struct layout-context
  (engine
   state
   action
   from-panel
   to-panel
   dir
   result)   ; before #f；after = 新 layout | #f
  #:transparent)

(define (make-layout-context engine state action
                             #:from-panel [from #f]
                             #:to-panel [to #f]
                             #:dir [dir #f]
                             #:result [result #f])
  (layout-context engine state action from to dir result))

(define (run-before registry operation ctx state)
  (run-before-hooks registry operation ctx state))

(define (run-after registry operation ctx state)
  (run-after-hooks registry operation ctx state))

(define (flash state text)
  (values (editor-state-with-flash state text) '()))

;;; ════════════════ split ════════════════

(define (editor-split! ed state dir)
  (define engine (editor-engine ed))
  (define l (editor-state-layout state))
  (define from (and l (layout-focus l)))
  (define p (and from (layout-panel l from)))
  (define src-vid (and p (p:panel-active p)))
  (cond
    [(not l) (flash state "split: no layout")]
    [(not p) (flash state "split: no focused panel")]
    [(not (eq? (p:panel-kind p) 'editor)) (flash state "split: focus is not editor")]
    [(not src-vid) (flash state "split: focused panel has no view")]
    [else
     (define ctx0 (make-layout-context engine state 'split #:from-panel from #:dir dir))
     (define-values (ctx1 state1 actions1 allow?)
       (run-before (editor-registry ed) 'layout-split ctx0 state))
     (cond
       [(not allow?) (values state1 actions1)]
       [else
        (define l1 (editor-state-layout state1))
        (define new-pid (editor-state-next-panel-id state1))
        (define new-vid (editor-state-next-view-id state1))
        (define-values (l2 ok?)
          (layout-split l1 from dir new-pid #:config (editor-state-layout-config state)))
        (cond
          [(not ok?) (flash state1 "split failed")]
          [else
           ;; 新 panel 需要自己的 view；不能把一个 view 同时挂在两个 panel。
           (void (engine-create-view-from-view! engine new-vid src-vid))
           (define-values (l3 added?)
             (layout-panel-add-view l2 new-pid new-vid))
           (define l4 (layout-set-focus l3 new-pid))
           ;; split 出来的 view 也属于同一个 resource。
           (define src-r (editor-state-resource-for-view state1 src-vid))
           (define resources*
             (if src-r
                 (resources-add-view (editor-state-resources state1)
                                     (resource-id src-r) new-vid)
                 (editor-state-resources state1)))
           (define state2
             (editor-state-with-next-panel-id
              (editor-state-with-next-view-id
               (editor-state-with-resources
                (editor-state-with-layout state1 l4)
                resources*)
               (add1 new-vid))
              (add1 new-pid)))
           (define ctx2
             (struct-copy layout-context ctx1
                          [state state2]
                          [to-panel new-pid]
                          [result l4]))
           (define-values (_ctx3 state3 actions3)
             (run-after (editor-registry ed) 'layout-split ctx2 state2))
           (values state3 (append actions1 actions3))])])]))

;;; ════════════════ close ════════════════

(define (editor-close! ed state)
  (define engine (editor-engine ed))
  (define l (editor-state-layout state))
  (define from (and l (layout-focus l)))
  (define p (and from (layout-panel l from)))
  (define editors (editor-visible-editor-panels state))
  (cond
    [(not l) (flash state "close: no layout")]
    [(not p) (flash state "close: no focused panel")]
    [(not (eq? (p:panel-kind p) 'editor)) (flash state "close: focus is not editor")]
    [(<= (length editors) 1) (flash state "close: last editor")]
    [else
     (define ctx0 (make-layout-context engine state 'close #:from-panel from))
     (define-values (ctx1 state1 actions1 allow?)
       (run-before (editor-registry ed) 'layout-close ctx0 state))
     (cond
       [(not allow?) (values state1 actions1)]
       [else
        (define l1 (editor-state-layout state1))
        (define-values (l2 ok?)
          (layout-panel-remove l1 from #:config (editor-state-layout-config state)))
        (cond
          [(not ok?) (flash state1 "close failed")]
          [else
           ;; 关闭 panel 只从布局摘掉；view / resource 仍然存在，可再 placement。
           (define state2 (editor-state-with-layout state1 l2))
           (define ctx2
             (struct-copy layout-context ctx1 [state state2] [result l2]))
           (define-values (_ctx3 state3 actions3)
             (run-after (editor-registry ed) 'layout-close ctx2 state2))
           (values state3 (append actions1 actions3))])])]))

;;; ════════════════ 鼠标 ════════════════

;; 鼠标坐标是屏幕绝对坐标（0 基）。
;; press:
;;   seam  -> 开始拖拽
;;   内容  -> 聚焦 panel + 把光标落到点击处
;;   border -> 只聚焦
;; move:
;;   拖拽中 -> layout-seam-drag-move
;; release:
;;   清掉 drag
;; scroll:
;;   滚指针下 panel 的 active view
(define (focus-hit state h)
  (define l (editor-state-layout state))
  (define id (hit-panel-id h))
  (define p (and l id (layout-panel l id)))
  (cond
    [(and p (layout-panel-focusable? l (editor-state-layout-config state) id))
     (editor-state-with-layout state (layout-set-focus l id))]
    [else state]))

(define (panel-active-view state pid)
  (define l (editor-state-layout state))
  (define p (and l pid (layout-panel l pid)))
  (and p (p:panel-active p)))

;; 拖选：选择留在按下的 panel 里，指针移到别的 panel 也不换目标。
(define (drag-select! ed state sd row col)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (define content (and l area (layout-content-rect l area (select-drag-panel-id sd))))
  (cond
    [(not content) (values state '())]
    [else
     (define r (- row (rect-y content)))
     (define c (- col (rect-x content)))
     (define h (rect-h content))
     (define vid (select-drag-view-id sd))
     (define-values (s1 a1)
       (cond
         [(< r 0) (surface-scroll! ed state vid -1)]
         [(>= r h) (surface-scroll! ed state vid 1)]
         [else (values state '())]))
     (define-values (s2 a2) (surface-set-point! ed s1 vid r c #t))
     (values s2 (append a1 a2))]))

(define (editor-mouse! ed state token row col)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (cond
    [(or (not l) (not area)) (values state '())]
    [else
     (case token
       [(press)
        (define h (layout-hit l area row col))
        (define seam (hit-seam h))
        (define state0 (editor-state-with-select-drag state #f))
        (cond
          [seam
           (define d (layout-seam-drag-start l area row col
                                             #:config (editor-state-layout-config state)
                                             #:seam seam
                                             #:solution (hit-solution h)))
           (values (editor-state-with-drag state0 d) '())]
          [else
           (define state1 (focus-hit state0 h))
           (define cid (hit-content-id h))
           (define cpanel (and cid l (layout-panel l cid)))
           (define vid (and cid (panel-active-view state1 cid)))
           (cond
             [(and vid cpanel (memq (p:panel-kind cpanel) '(editor sidebar)))
              (define-values (s2 a2)
                (surface-set-point! ed state1 vid
                                    (hit-content-row h)
                                    (hit-content-col h)))
              (values (editor-state-with-select-drag
                       s2 (select-drag cid vid))
                      a2)]
             [else (values state1 '())])])]

       [(move)
        (define d (editor-state-drag state))
        (define sd (editor-state-select-drag state))
        (cond
          [d
           (define-values (l* ok?)
             (layout-seam-drag-move l area d row col
                                    #:config (editor-state-layout-config state)))
           (values (if ok?
                       (editor-state-with-layout state l*)
                       state)
                   '())]
          [sd (drag-select! ed state sd row col)]
          [else (values state '())])]

       [(release)
        (values (editor-state-with-select-drag (editor-state-with-drag state #f) #f) '())]

       [(scroll-up scroll-down)
        (define h (layout-hit l area row col))
        (define vid (panel-active-view state (hit-panel-id h)))
        (cond
          [vid
           (surface-scroll! ed state vid
                            (if (eq? token 'scroll-up) -3 3))]
          [else (values state '())])]

       [else (values state '())])]))

;;; ════════════════ focus ════════════════

;; 侧栏 tab：filetree <-> resources。
(define (sidebar-panel-id state)
  (define l (editor-state-layout state))
  (define focus (and l (layout-focus l)))
  (define fp (and focus (layout-panel l focus)))
  (cond
    [(and fp (eq? (p:panel-kind fp) 'sidebar)) focus]
    [l (for/first ([pid (in-list (layout-panel-ids l))]
                   #:when (eq? (p:panel-kind (layout-panel l pid)) 'sidebar))
         pid)]
    [else #f]))

(define (editor-cycle-sidebar-view! ed state)
  (define l (editor-state-layout state))
  (define pid (sidebar-panel-id state))
  (cond
    [(not pid) (flash state "sidebar: no panel")]
    [else
     (define-values (l* ok?) (layout-panel-cycle-active-view l pid))
     (cond
       [ok? (values (editor-state-with-layout state l*) '())]
       [else (flash state "sidebar: only one view")])]))

;; 通用 panel 显隐（docs 等）。
(define (editor-toggle-panel! ed state pid)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (cond
    [(or (not l) (not area) (not pid)) (flash state "panel: no target")]
    [else
     (define visible? (layout-panel-visible? l pid))
     (define-values (l* ok?)
       (if visible?
           (layout-panel-hide l area pid #:config (editor-state-layout-config state))
           (layout-panel-show l area pid)))
     (if ok?
         (values (editor-state-with-layout state l*) '())
         (flash state "panel toggle failed"))]))

(define (editor-cycle-editor-view! ed state [step 1])
  (define p (editor-focus-panel state))
  (cond
    [(or (not p) (not (eq? (p:panel-kind p) 'editor)))
     (flash state "tab: focus is not editor")]
    [else
     (define l (editor-state-layout state))
     (define-values (l* ok?)
       (layout-panel-cycle-active-view l (p:panel-id p) step))
     (if ok?
         (values (editor-state-with-layout state l*) '())
         (flash state "tab: panel has no views"))]))

(define (editor-toggle-sidebar! ed state)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (define pid (sidebar-panel-id state))
  (cond
    [(or (not l) (not area) (not pid))
     (flash state "sidebar: no panel")]
    [else
     (define visible? (layout-panel-visible? l pid))
     (define-values (l* ok?)
       (if visible?
           (layout-panel-hide l area pid #:config (editor-state-layout-config state))
           (layout-panel-show l area pid)))
     (if ok?
         (values (editor-state-with-layout state l*) '())
         (flash state "sidebar toggle failed"))]))

(define (editor-focus! ed state dir)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (define from (and l (layout-focus l)))
  (cond
    [(or (not l) (not area)) (flash state "focus: no layout / area")]
    [else
     (define to (layout-focus-neighbor l area (editor-state-layout-config state) from dir))
     (cond
       [(not to) (flash state "no focus neighbor")]
       [else
        (define ctx0
          (make-layout-context (editor-engine ed) state 'focus
                               #:from-panel from #:to-panel to #:dir dir))
        (define-values (ctx1 state1 actions1 allow?)
          (run-before (editor-registry ed) 'layout-focus ctx0 state))
        (cond
          [(not allow?) (values state1 actions1)]
          [else
           (define l1 (editor-state-layout state1))
           (define l2 (layout-set-focus l1 to))
           (define state2 (editor-state-with-layout state1 l2))
           (define ctx2
             (struct-copy layout-context ctx1 [state state2] [result l2]))
           (define-values (_ctx3 state3 actions3)
             (run-after (editor-registry ed) 'layout-focus ctx2 state2))
           (values state3 (append actions1 actions3))])])]))

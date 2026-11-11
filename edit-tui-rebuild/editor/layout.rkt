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
         "hooks.rkt"
         "action.rkt"
         "ops/surface.rkt")

(provide (struct-out layout-context)
         make-layout-context
         editor-layout-config
         make-editor-layout
         editor-layout-panels
         editor-focus-panel-id
         editor-focus-panel
         editor-focus-view-id
         editor-focus-view
         editor-visible-editor-panels
         editor-split!
         editor-close!
         editor-focus!
         editor-mouse!)

;;; ════════════════ 配置 ════════════════

(define editor-layout-config
  (make-layout-config
   #:rules
   (hash
    'editor
    (make-panel-rule #:splittable? #t
                     #:hideable? #f
                     #:deletable? #t
                     #:focusable? #t
                     #:min-w 1 #:max-w #f
                     #:min-h 1 #:max-h #f)
    'status
    (make-panel-rule #:splittable? #f
                     #:hideable? #f
                     #:deletable? #f
                     #:focusable? #f
                     #:min-w 1 #:max-w #f
                     #:min-h 1 #:max-h #f))))

;;; ════════════════ 初始布局 ════════════════

;; editor 叶子 + 可选 status 固定在底部 1 行。
(define (make-editor-layout #:editor-view editor-vid
                            #:editor-panel-id [editor-pid 'editor]
                            #:status-view [status-vid #f]
                            #:status-panel-id [status-pid 'status])
  (define editor-panel
    (p:make-panel editor-pid 'editor
                  #:views (list editor-vid)
                  #:active editor-vid
                  #:borders '(up down left right)))
  (define l0
    (make-layout #:root (make-leaf editor-pid)
                 #:panels (hash editor-pid editor-panel)
                 #:focus editor-pid))
  (cond
    [(not status-vid) l0]
    [else
     (define status-panel
       (p:make-panel status-pid 'status
                     #:views (list status-vid)
                     #:active status-vid
                     #:fixed-h 1))
     (define-values (l1 ok?)
       (layout-panel-attach l0 editor-pid 'down status-panel))
     (unless ok?
       (error 'make-editor-layout "status attach failed"))
     l1]))

;;; ════════════════ 查询 ════════════════

(define (editor-focus-panel-id state)
  (define l (editor-state-layout state))
  (and l (layout-focus l)))

(define (editor-focus-panel state)
  (define l (editor-state-layout state))
  (and l (layout-panel l (layout-focus l))))

(define (editor-focus-view-id state)
  (define p (editor-focus-panel state))
  (and p (p:panel-active p)))

(define (editor-focus-view ed state)
  (define vid (editor-focus-view-id state))
  (and vid (engine-view-object (editor-engine ed) vid)))

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
          (layout-split l1 from dir new-pid #:config editor-layout-config))
        (cond
          [(not ok?) (flash state1 "split failed")]
          [else
           ;; 新 panel 需要自己的 view；不能把一个 view 同时挂在两个 panel。
           (void (engine-create-view-from-view! engine new-vid src-vid))
           (define-values (l3 added?)
             (layout-panel-add-view l2 new-pid new-vid))
           (define l4 (layout-set-focus l3 new-pid))
           (define state2
             (struct-copy editor-state state1
                          [layout l4]
                          [next-panel-id (add1 new-pid)]
                          [next-view-id (add1 new-vid)]))
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
          (layout-panel-remove l1 from #:config editor-layout-config))
        (cond
          [(not ok?) (flash state1 "close failed")]
          [else
           (define vid (p:panel-active p))
           (when vid (engine-remove-view! engine vid))
           (define state2 (struct-copy editor-state state1 [layout l2]))
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
    [(and p (layout-panel-focusable? l editor-layout-config id))
     (struct-copy editor-state state [layout (layout-set-focus l id)])]
    [else state]))

(define (panel-active-view state pid)
  (define l (editor-state-layout state))
  (define p (and l pid (layout-panel l pid)))
  (and p (p:panel-active p)))

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
        (cond
          [seam
           (define d (layout-seam-drag-start l area row col
                                             #:config editor-layout-config
                                             #:seam seam
                                             #:solution (hit-solution h)))
           (values (struct-copy editor-state state [drag d]) '())]
          [else
           (define state1 (focus-hit state h))
           (define cid (hit-content-id h))
           (define cpanel (and cid l (layout-panel l cid)))
           (define vid (and cid (panel-active-view state1 cid)))
           (cond
             [(and vid cpanel (eq? (p:panel-kind cpanel) 'editor))
              (surface-set-point! ed state1 vid
                                  (hit-content-row h)
                                  (hit-content-col h))]
             [else (values state1 '())])])]

       [(move)
        (define d (editor-state-drag state))
        (cond
          [(not d) (values state '())]
          [else
           (define-values (l* ok?)
             (layout-seam-drag-move l area d row col
                                    #:config editor-layout-config))
           (values (if ok?
                       (struct-copy editor-state state [layout l*])
                       state)
                   '())])]

       [(release)
        (values (struct-copy editor-state state [drag #f]) '())]

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

(define (editor-focus! ed state dir)
  (define l (editor-state-layout state))
  (define area (editor-state-area state))
  (define from (and l (layout-focus l)))
  (cond
    [(or (not l) (not area)) (flash state "focus: no layout / area")]
    [else
     (define to (layout-focus-neighbor l area editor-layout-config from dir))
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
           (define state2 (struct-copy editor-state state1 [layout l2]))
           (define ctx2
             (struct-copy layout-context ctx1 [state state2] [result l2]))
           (define-values (_ctx3 state3 actions3)
             (run-after (editor-registry ed) 'layout-focus ctx2 state2))
           (values state3 (append actions1 actions3))])])]))

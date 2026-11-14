#lang racket

;;; edit-tui/features/mouse/mouse.rkt —— 鼠标会话
;;;
;;; 鼠标坐标是屏幕绝对坐标（0 基）。
;;; press:
;;;   seam   -> 开始拖拽
;;;   内容   -> 聚焦 panel + 把光标落到点击处
;;;   border -> 只聚焦
;;; move:
;;;   拖拽中 -> layout-seam-drag-move
;;; release:
;;;   清掉 drag
;;; scroll:
;;;   滚指针下 panel 的 active view
;;;
;;; 这里只处理“鼠标手势 -> editor 操作 / session 状态”；
;;; 布局结构操作仍在 editor/layout.rkt。

(require "../../core/layout/api.rkt"
         "../../core/focus/api.rkt"
         "../../core/projection/api.rkt"
         (prefix-in p: "../../core/panel/api.rkt")
         "../../editor/api.rkt")

(provide editor-mouse!)

(define (focus-hit state h)
  (define l (state-layout state))
  (define id (hit-panel-id h))
  (define p (and l id (layout-panel l id)))
  (cond
    [(and p (layout-panel-focusable? l (state-layout-config state) id))
     (state-with-layout state (layout-set-focus l id))]
    [else state]))

(define (panel-active-view state pid)
  (define l (state-layout state))
  (define p (and l pid (layout-panel l pid)))
  (and p (p:panel-active p)))

;; 拖选：选择留在按下的 panel 里，指针移到别的 panel 也不换目标。
(define (drag-select! ed state sd row col)
  (define l (state-layout state))
  (define area (state-screen state))
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
         [(< r 0) (editor-scroll! ed state vid -1)]
         [(>= r h) (editor-scroll! ed state vid 1)]
         [else (values state '())]))
     (define-values (s2 a2) (editor-set-point! ed s1 vid r c #t))
     (values s2 (append a1 a2))]))

(define (editor-mouse! ed state token row col)
  (define l (state-layout state))
  (define area (state-screen state))
  (cond
    [(or (not l) (not area)) (values state '())]
    [else
     (case token
       [(press)
        (define h (layout-hit l area row col))
        (define seam (hit-seam h))
        (define state0 (state-with-select-drag state #f))
        (cond
          [seam
           (define d (layout-seam-drag-start l area row col
                                             #:config (state-layout-config state)
                                             #:seam seam
                                             #:solution (hit-solution h)))
           (values (state-with-drag state0 d) '())]
          [else
           (define state1 (focus-hit state0 h))
           (define cid (hit-content-id h))
           (define cpanel (and cid l (layout-panel l cid)))
           (define vid (and cid (panel-active-view state1 cid)))
           (cond
             [(and vid cpanel (memq (p:panel-kind cpanel) '(editor sidebar)))
              (define-values (s2 a2)
                (editor-set-point! ed state1 vid
                                   (hit-content-row h)
                                   (hit-content-col h)))
              (values (state-with-select-drag s2 (select-drag cid vid)) a2)]
             [else (values state1 '())])])]

       [(move)
        (define d (state-drag state))
        (define sd (state-select-drag state))
        (cond
          [d
           (define-values (l* ok?)
             (layout-seam-drag-move l area d row col
                                    #:config (state-layout-config state)))
           (values (if ok? (state-with-layout state l*) state) '())]
          [sd (drag-select! ed state sd row col)]
          [else (values state '())])]

       [(release)
        (values (state-with-select-drag (state-with-drag state #f) #f) '())]

       [(scroll-up scroll-down)
        (define h (layout-hit l area row col))
        (define vid (panel-active-view state (hit-panel-id h)))
        (cond
          [vid
           (editor-scroll! ed state vid
                           (if (eq? token 'scroll-up) -3 3))]
          [else (values state '())])]

       [else (values state '())])]))

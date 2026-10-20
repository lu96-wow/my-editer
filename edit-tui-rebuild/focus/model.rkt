#lang racket

;;; edit-tui-rebuild/focus/model.rkt —— 焦点导航（纯）
;;;
;;; 规则：
;;;   · 只在 visible + focusable 的 panel 里走；
;;;   · 方向导航复用 core 的 panel-neighbor（几何最近）；
;;;   · 鼠标命中：先找覆盖点的 panel，再检查 focusable；
;;;   · hidden panel 不在 layout-solve 的 rects 里，自然不参与。

(provide layout-panel-focusable?
         layout-focusable-panels
         layout-focus-panel-at
         layout-focus-neighbor)

(require (prefix-in l: "../layout/tree.rkt")
         (prefix-in l: "../layout/solve.rkt")
         (prefix-in p: "../panel/model.rkt")
         "../config/model.rkt"
         "../projection/geometry.rkt"
         "../../core/view/panel.rkt")

(define (layout-panel-focusable? layout config id)
  (define p (l:layout-panel layout id))
  (and p
       (p:panel-visible? p)
       (config-panel-focusable? config (p:panel-kind p))))

;; 方向导航用的 core panel：view = panel-id，只保留可聚焦 panel。
(define (layout-focusable-panels layout area config)
  (for/list ([p (in-list (layout->hit-panels layout area))]
             #:when (layout-panel-focusable? layout config (panel-view p)))
    p))

;; 鼠标坐标 → 可聚焦 panel-id | #f
(define (layout-focus-panel-at layout area config row col)
  (define id (l:layout-panel-id-at layout area row col))
  (and id (layout-panel-focusable? layout config id) id))

;; 方向导航：left / right / up / down → panel-id | #f
(define (layout-focus-neighbor layout area config from-id dir)
  (define panels (layout-focusable-panels layout area config))
  (define from
    (for/first ([p (in-list panels)]
                #:when (equal? (panel-view p) from-id))
      p))
  (define nbr (and from (panel-neighbor panels from dir)))
  (and nbr (panel-view nbr)))

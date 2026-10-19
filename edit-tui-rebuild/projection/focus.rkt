#lang racket

;;; edit-tui-rebuild/projection/focus.rkt —— 焦点导航（纯）
;;;
;;; 规则：
;;;   · 只在 visible + focusable 的 panel 里走；
;;;   · 方向导航直接复用 core 的 panel-neighbor（几何最近）；
;;;   · 鼠标命中：先找覆盖点的 panel，再检查 focusable；
;;;   · hidden panel 不在 layout-pass 的 rects 里，自然不参与。

(provide layout-focusable?
         layout-focus-panels
         layout-focus-at
         layout-neighbor
         layout-focus-move)

(require (prefix-in l: "../model/layout.rkt")
         (prefix-in p: "../model/panel.rkt")
         "../model/config.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/view/panel.rkt")

(define (layout-focusable? layout config id)
  (define p (l:layout-panel layout id))
  (and p
       (p:panel-visible? p)
       (config-focusable? config (p:panel-kind p))))

;; 命中 / 方向导航用的 core panel：view = panel-id。
(define (layout-focus-panels layout area config)
  (define pass (l:layout-pass layout area))
  (define rects (l:pass-rects pass))
  (for/list ([id (in-list (l:layout-visible-panel-ids layout))]
             #:when (layout-focusable? layout config id))
    (define p (l:layout-panel layout id))
    (define r (hash-ref rects id))
    (make-panel id r
                (p:panel-borders p)
                #:face (p:panel-face p)
                #:weight (p:panel-weight p))))

;; 鼠标坐标 → 可聚焦 panel-id | #f
(define (layout-focus-at layout area config row col)
  (define pass (l:layout-pass layout area))
  (for/first ([(id r) (in-hash (l:pass-rects pass))]
              #:when (and (rect-contains? r col row)
                          (layout-focusable? layout config id)))
    id))

;; 方向导航：left / right / up / down → panel-id | #f
(define (layout-neighbor layout area config from-id dir)
  (define panels (layout-focus-panels layout area config))
  (define from
    (for/first ([p (in-list panels)]
                #:when (equal? (panel-view p) from-id))
      p))
  (define nbr (and from (panel-neighbor panels from dir)))
  (and nbr (panel-view nbr)))

(define (layout-focus-move layout area config from-id dir)
  (layout-neighbor layout area config from-id dir))

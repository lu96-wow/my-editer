#lang racket

;;; core/view/layout.rkt —— 面板摆放层：panels → placements + border-runs。
(require rackunit
         "../../core/view/layout.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt")

(define p (make-panel 'v (rect 2 1 6 4) borders-all #:deep 3 #:face 'f))
(define lay (panels->layout (list p)))

;; placements = (view 内容 rect deep)；内容 rect 按存在的边各内缩 1
(check-equal? (layout-placements lay) (list (list 'v (rect 3 2 4 2) 3)))

;; border-runs 非空，且每条都带该 panel 的 face / deep
(check-true (pair? (layout-border-runs lay)))
(check-true (for/and ([r (in-list (layout-border-runs lay))])
              (and (eq? (list-ref r 3) 'f) (= (list-ref r 4) 3))))

;; 空面板：有 placements（view = #f）也有边框，内容区照算
(define pe (empty-panel (rect 0 0 4 3) borders-all))
(check-equal? (layout-placements (panels->layout (list pe))) (list (list #f (rect 1 1 2 1) 0)))

(displayln "view/layout.rkt: ok")

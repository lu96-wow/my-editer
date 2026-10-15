#lang racket

;;; 由 core/editor/query.rkt 的测试外移而来（core 只留实现）。
(require rackunit
         "../../core/editor.rkt")

(define b (make-buffer "hello\nworld\n"))
(define v (buffer-add-view! b 18 4 #:line-numbers? #f))   ; 内容 18×4
(define p (make-panel v (rect 5 2 20 6) borders-all))     ; 内容原点 = (6,3)

;; panel 屏坐标 ↔ 文档点 ↔ panel 屏坐标
(check-equal? (call-with-values (λ () (panel-screen-position->point p 3 6)) list) '(0 0))
(check-equal? (call-with-values (λ () (panel-screen-position->point p 3 8)) list) '(0 2))
(check-equal? (call-with-values (λ () (panel-point->screen-position p (point 0 0))) list) '(3 6))
(check-equal? (call-with-values (λ () (panel-point->screen-position p (point 1 3))) list) '(4 9))
;; 内容外 / 越界 → (values #f #f)
(check-equal? (call-with-values (λ () (panel-screen-position->point p 100 100)) list) '(#f #f))
(check-equal? (call-with-values (λ () (panel-screen-position->point p 0 0)) list) '(#f #f))

(displayln "core/editor/query.rkt: ok")

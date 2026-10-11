#lang racket

;;; edit2-test/layout.rkt —— edit2/layout.rkt 的外部测试

(require rackunit
         "../../edit2/core/layout.rkt"
         "../../edit2/core/state.rkt")

;; 左右平分（flex）
(define t (split 'h (list (cons 'flex (pane 'a)) (cons 'flex (pane 'b)))))
(define ps (layout t (cons 80 24)))
(check-equal? (placement-rect (list-ref ps 0)) (rect 0 0 40 24))
(check-equal? (placement-rect (list-ref ps 1)) (rect 40 0 40 24))

;; 固定 1 行 + flex
(define t2 (split 'v (list (cons 'flex (pane 'a)) (cons 1 (pane 'b)))))
(define ps2 (layout t2 (cons 10 4)))
(check-equal? (placement-rect (list-ref ps2 0)) (rect 0 0 10 3))
(check-equal? (placement-rect (list-ref ps2 1)) (rect 0 3 10 1))

;; 浮窗贴屏幕右下，z 更高
(define t3 (float 'f (anchor #f 'right 'bottom 0 0) 20 6))
(define ps3 (layout t3 (cons 80 24)))
(check-equal? (placement-rect (car ps3)) (rect 60 18 20 6))
(check-true (placement-float? (car ps3)))
(check-equal? (placement-z (car ps3)) 1)

;; 浮窗相对某窗格
(define t4 (split 'h (list (cons 'flex (pane 'a))
                           (cons 0 (float 'f (anchor 'a 'left 'top 1 1) 10 3)))))
(define ps4 (layout t4 (cons 40 10)))
(define fp (for/first ([p (in-list ps4)] #:when (eqv? (placement-vid p) 'f)) p))
(check-equal? (placement-rect fp) (rect 1 1 10 3))

;; 超过屏幕的浮窗被 clamp
(define t5 (float 'f (anchor #f 'right 'bottom 0 0) 999 999))
(check-equal? (placement-rect (car (layout t5 (cons 10 4)))) (rect 0 0 10 4))

;; 命中定位：坐标 → 窗格
(define ph (layout (split 'h (list (cons 'flex (pane 'a)) (cons 'flex (pane 'b)))) (cons 10 4)))
(check-equal? (placement-vid (layout-hit ph 2 1)) 'a)
(check-equal? (placement-vid (layout-hit ph 7 1)) 'b)
(check-false (layout-hit ph 20 1))
(check-equal? (call-with-values (lambda () (rect-local (layout-hit ph 7 2) 7 2)) list)
              (list 'b 2 2))
;; 浮窗命中优先（z 高）
(define pf (layout (split 'h (list (cons 'flex (pane 'a))
                                  (cons 0 (float 'f (anchor #f 'left 'top 0 0) 4 2))))
                   (cons 10 4)))
(check-equal? (placement-vid (layout-hit pf 1 0)) 'f)
(check-equal? (placement-vid (layout-hit pf 5 0)) 'a)

;; 布局树手术
(check-equal? (layout-vids (split 'h (list (cons 'flex (pane 'a)) (cons 1 (pane 'b))))) '(a b))
(check-true (layout-has? (split 'h (list (cons 'flex (pane 'a)) (cons 1 (pane 'b)))) 'b))
(check-equal? (layout-vids (layout-remove (split 'h (list (cons 'flex (pane 'a)) (cons 1 (pane 'b)))) 'a))
              '(b))

(displayln "edit2/layout.rkt: all tests passed")

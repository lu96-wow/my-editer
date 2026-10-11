#lang racket

;;; edit2-test/layout.rkt —— edit2/layout.rkt 的外部测试（wid / vid 分离）

(require rackunit
         racket/list
         "../../edit2/core/layout.rkt"
         "../../edit2/core/state.rkt")

;; 左右平分（flex）
(define t (split 'h (list (cons 'flex (pane 'wa 'a)) (cons 'flex (pane 'wb 'b)))))
(define ps (layout t (cons 80 24)))
(check-equal? (placement-rect (list-ref ps 0)) (rect 0 0 40 24))
(check-equal? (placement-rect (list-ref ps 1)) (rect 40 0 40 24))

;; 固定 1 行 + flex
(define t2 (split 'v (list (cons 'flex (pane 'wa 'a)) (cons 1 (pane 'wb 'b)))))
(define ps2 (layout t2 (cons 10 4)))
(check-equal? (placement-rect (list-ref ps2 0)) (rect 0 0 10 3))
(check-equal? (placement-rect (list-ref ps2 1)) (rect 0 3 10 1))

;; 浮窗贴屏幕右下，z 更高
(define t3 (float 'wf 'f (anchor #f 'right 'bottom 0 0) 20 6))
(define ps3 (layout t3 (cons 80 24)))
(check-equal? (placement-rect (car ps3)) (rect 60 18 20 6))
(check-true (placement-float? (car ps3)))
(check-equal? (placement-z (car ps3)) 1)

;; 浮窗相对某窗口
(define t4 (split 'h (list (cons 'flex (pane 'wa 'a))
                           (cons 0 (float 'wf 'f (anchor 'wa 'left 'top 1 1) 10 3)))))
(define ps4 (layout t4 (cons 40 10)))
(define fp (for/first ([p (in-list ps4)] #:when (eqv? (placement-wid p) 'wf)) p))
(check-equal? (placement-rect fp) (rect 1 1 10 3))

;; 超过屏幕的浮窗被 clamp
(define t5 (float 'wf 'f (anchor #f 'right 'bottom 0 0) 999 999))
(check-equal? (placement-rect (car (layout t5 (cons 10 4)))) (rect 0 0 10 4))

;; 命中定位：坐标 → 窗口；同 view 多位置也命中各自 wid
(define ph (layout (split 'h (list (cons 'flex (pane 'wa 'a)) (cons 'flex (pane 'wb 'b)))) (cons 10 4)))
(check-equal? (placement-wid (layout-hit ph 2 1)) 'wa)
(check-equal? (placement-vid (layout-hit ph 2 1)) 'a)
(check-equal? (placement-wid (layout-hit ph 7 1)) 'wb)
(check-false (layout-hit ph 20 1))
(check-equal? (call-with-values (lambda () (rect-local (layout-hit ph 7 2) 7 2)) list)
              (list 'wb 2 2))
;; 浮窗命中优先（z 高）
(define pf (layout (split 'h (list (cons 'flex (pane 'wa 'a))
                                  (cons 0 (float 'wf 'f (anchor #f 'left 'top 0 0) 4 2))))
                   (cons 10 4)))
(check-equal? (placement-wid (layout-hit pf 1 0)) 'wf)
(check-equal? (placement-wid (layout-hit pf 5 0)) 'wa)

;; 同 view 多位置：两个窗口不同 wid，同一个 vid，各自有 placement
(define tm (split 'h (list (cons 'flex (pane 'w1 'a)) (cons 'flex (pane 'w2 'a)))))
(define psm (sort (layout tm (cons 20 4)) < #:key (lambda (p) (rect-x (placement-rect p)))))
(check-equal? (length psm) 2)
(check-equal? (map placement-wid psm) '(w1 w2))
(check-equal? (map placement-vid psm) '(a a))

;; 布局树手术：wid 是窗口身份
(define th (split 'h (list (cons 'flex (pane 'wa 'a)) (cons 1 (pane 'wb 'b)))))
(check-equal? (layout-wids th) '(wa wb))
(check-equal? (layout-vids th) '(a b))
(check-true (layout-has-wid? th 'wb))
(check-true (layout-has? th 'b))
(check-equal? (layout-wid-vid th 'wb) 'b)
(check-equal? (layout-wid-of-vid th 'b) 'wb)
(check-equal? (layout-wids (layout-remove-wid th 'wa)) '(wb))
;; 按 vid 删会清掉所有显示它的窗口
(define tm2 (split 'h (list (cons 'flex (pane 'w1 'a)) (cons 'flex (pane 'w2 'a)))))
(check-equal? (layout-wids (layout-remove-vid tm2 'a)) '())
;; 改窗口显示的视图
(check-equal? (layout-wid-vid (layout-set-pane-vid th 'wb 'a) 'wb) 'a)
;; 分裂新建窗口
(define ts (layout-split-wid (pane 'wa 'a) 'wa 'h 'w2 'a))
(check-equal? (layout-wids ts) '(wa w2))
(check-equal? (layout-vids ts) '(a a))

(displayln "edit2/layout.rkt: all tests passed")

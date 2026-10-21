#lang racket

;;; face 值 / 分层合成测试。
(require rackunit
         "../main.rkt")

(define f0 (face-set-fg #f 'red))
(check-true (face? f0))
(check-equal? (face-fg f0) 'red)
(check-false (face-bg f0))

(define f1 (face-set-bg f0 'blue))
(check-equal? (face-fg f1) 'red)
(check-equal? (face-bg f1) 'blue)

(define f2 (face-add-attr f1 'bold))
(define f3 (face-add-attr f2 'underline))
(check-true (face-has-attr? f3 'bold))
(check-true (face-has-attr? f3 'underline))
(check-equal? (face-attrs f3) '(bold underline))
(check-equal? (face-attrs (face-add-attr f3 'bold)) '(bold underline)) ; 幂等
(check-equal? (face-attrs (face-remove-attr f3 'bold)) '(underline))

;; 逐分量合成
(define a (face-set-fg #f 'fg1))
(define b (face-set-bg #f 'bg1))
(check-equal? (compose-face a b) (face 'fg1 'bg1 '()))
(check-equal? (compose-face a (face-set-fg #f 'fg2)) (face 'fg2 #f '()))

;; 裸 symbol 整体覆盖
(check-eq? (compose-face a 'whole) 'whole)
(check-equal? (compose-face 'whole b) b)

;; 多层 fills
(define layers
  (hash 'fg (list (list 0 0 0 2 (face 'red #f '())))
        'bg (list (list 0 1 0 3 (face #f 'blue '())))))
(define fills (compose-layers '(fg bg) layers))
;; [0,1) red；[1,2) red+blue；[2,3) blue
(check-equal? fills
              (list (list 0 0 0 1 (face 'red #f '()))
                    (list 0 1 0 2 (face 'red 'blue '()))
                    (list 0 2 0 3 (face #f 'blue '()))))

;; 未声明的层按名字追加（不丢）
(define fills2 (compose-layers '(fg) (hash 'fg (list (list 0 0 0 1 (face 'red #f '())))
                                            'zz (list (list 0 0 0 1 (face #f 'bg '()))))))
(check-equal? (car fills2) (list 0 0 0 1 (face 'red 'bg '())))

;; 跨行 fill：中间行按 line-length 展开，不再使用 +inf.0
(define cross
  (compose-layers '(fg)
                  (hash 'fg (list (list 0 1 2 3 (face 'red #f '()))))
                  #:line-length (λ (_line) 5)))
(check-equal? cross
              (list (list 0 1 0 5 (face 'red #f '()))
                    (list 1 0 1 5 (face 'red #f '()))
                    (list 2 0 2 3 (face 'red #f '()))))

;; 不传 line-length 时用 c1 作为有限上界（至少不会死循环）
(define cross-fallback
  (compose-layers '(fg)
                  (hash 'fg (list (list 0 1 2 3 (face 'red #f '()))))))
(check-equal? cross-fallback
              (list (list 0 1 0 3 (face 'red #f '()))
                    (list 1 0 1 3 (face 'red #f '()))
                    (list 2 0 2 3 (face 'red #f '()))))

(displayln "edit-tui-rebuild/test/face.rkt: ok")

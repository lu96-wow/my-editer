#lang racket

;;; edit2-test/state.rkt —— edit2/state.rkt 的外部测试

(require rackunit
         "../../edit2/core/state.rkt")

(define s (make-state))
(check-equal? (state-docs s) (hash))
(check-equal? (state-stack s) '())
(check-true (blank? (state-layout s)))
(check-false (feature-ref s 'nope #f))
(check-equal? (feature-ref (feature-set s 'x 1) 'x #f) 1)

(displayln "edit2/state.rkt: all tests passed")

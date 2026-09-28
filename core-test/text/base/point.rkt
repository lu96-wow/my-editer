#lang racket

;; 由 core/text/base/point.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core/text/base/point.rkt"
       "../../../core/text/base/track.rkt"
       "../../../core/text/base/line.rkt")

(check-equal? (point 2 3) (point 2 3))
(check-true  (point<? (point 1 9) (point 2 0)))
(check-true  (point<? (point 1 1) (point 1 2)))
(check-false (point<? (point 1 2) (point 1 2)))
(check-true  (point<=? (point 1 2) (point 1 2)))
(check-equal? (point=? (point 4 0) (point 4 0)) #t)
(check-equal? (point=? (point 4 0) (point 0 4)) #f)
(check-true (pos<? 0 5 1 0))
(check-true (pos=? 3 2 3 2))
(check-true (pos<=? 3 2 3 2))

(define (len l) (list-ref '(2 3 5) l))
(check-equal? (point-clamp (point 1 1) 3 len) (point 1 1))
(check-equal? (point-clamp (point 9 9) 3 len) (point 2 5))
(check-equal? (point-clamp (point -2 -2) 3 len) (point 0 0))
(check-equal? (point-clamp (point 1 99) 3 len) (point 1 3))

(define t (track-of-list (list "中a" "abc" "")))
(check-equal? (point-right t (point 0 0)) (point 0 1))
(check-equal? (point-right t (point 0 2)) (point 1 0))
(check-equal? (point-left t (point 1 0)) (point 0 2))
(check-equal? (point-left t (point 0 0)) (point 0 0))
(check-equal? (point-right t (point 2 0)) (point 2 0))
(check-equal? (point-home t (point 1 2)) (point 1 0))
(check-equal? (point-end t (point 0 0)) (point 0 2))
(check-equal? (point-end t (point 1 0)) (point 1 3))

(displayln "point.rkt: all tests passed")

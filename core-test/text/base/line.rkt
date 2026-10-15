#lang racket

;; 由 core/text/base/line.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core/text/base/line.rkt")

;; 文本行：string（按字符，不按字节）
(check-equal? (line-length "a中b") 3)
(check-equal? (line-ref "a中b" 1) #\中)
(check-equal? (line-splice "abc" 1 1 "X") "aXbc")
(check-equal? (line-splice "abc" 0 3 "X") "X")
(check-equal? (line-delete "abcdef" 1 3) "adef")
(check-equal? (line-insert-sticky "abc" 2 2 'left) "abbbc")

;; 属性行：vector
(define v (vector 'none 'bold 'bold 'none))
(check-equal? (line-length v) 4)
(check-equal? (line-ref v 1) 'bold)
(check-equal? (line-splice v 2 2 (vector 'x)) (vector 'none 'bold 'x 'bold 'none))
(check-equal? (line-delete v 1 3) (vector 'none 'none))
(check-equal? (line-insert-sticky v 2 1 'left 'none) (vector 'none 'bold 'bold 'bold 'none))
(check-equal? (line-insert-sticky v 2 1 'right 'none) (vector 'none 'bold 'bold 'bold 'none))

;; 类型工具
(check-equal? (line->list "a中") (list #\a #\中))
(check-equal? (line-of-like v '(a b)) (vector 'a 'b))
(check-equal? (line-of-like "x" '(#\a #\b)) "ab")
(check-equal? (line-empty-like v) (vector))
(check-equal? (line-empty-like "x") "")

(displayln "line.rkt: all tests passed")

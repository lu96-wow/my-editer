#lang racket

(require rackunit)

;;; atom/restrict.rkt —— 约束槽的值
;;;
;;; core **解释**的语义（与表现层 face 相反）：目前只有 read-only。
;;; 加约束 = 加字段（编译期可见）；这是文档里与 content 并列的那个槽。

(provide
 (struct-out restrict)
 restrict-empty
 restrict-empty?)

(struct restrict (read-only?) #:transparent)

(define (restrict-empty) (restrict #f))
(define (restrict-empty? r) (equal? r (restrict-empty)))

;;; ---------- 测试 ----------

(module+ test
  (check-false (restrict-read-only? (restrict-empty)))
  (check-true (restrict-read-only? (restrict #t)))
  (check-true (restrict-empty? (restrict-empty)))
  (check-false (restrict-empty? (restrict #t)))
  (displayln "restrict.rkt: all tests passed"))

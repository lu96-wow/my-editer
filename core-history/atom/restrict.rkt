#lang racket

(require rackunit)

;;; atom/restrict.rkt —— 约束槽的值
;;;
;;; core **解释**的语义（与表现层 face 相反）：目前只有 read-only。
;;; 加约束 = 加字段（编译期可见）；这是 properties 两个槽中的一个。

(provide
 (struct-out restrict)
 make-restrict
 restrict-empty?)

(struct restrict (read-only?) #:transparent)

(define (make-restrict) (restrict #f))
(define (restrict-empty? r) (equal? r (make-restrict)))

;;; ---------- 测试 ----------

(module+ test
  (check-false (restrict-read-only? (make-restrict)))
  (check-true (restrict-read-only? (restrict #t)))
  (check-true (restrict-empty? (make-restrict)))
  (check-false (restrict-empty? (restrict #t)))
  (displayln "restrict.rkt: all tests passed"))

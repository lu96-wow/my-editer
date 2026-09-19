#lang racket

;;; point.rkt —— 文档位置 (line, col)，全部 0-based。
;;;
;;; 这是 core 里**唯一**的位置表示。规范：
;;;   · 任何「要位置」的函数收 point（不收散着的 line col 两参数）。
;;;   · 任何「给位置」的函数返回 point。
;;; 这样位置的传递永远是一个值，不会出现「两个数字谁先谁后」的约定。
;;;
;;; point **不知道**它所在行有多长、有没有文本；合法性由调用方用 point-clamp 保证。

(provide
 (struct-out point)
 point<?
 point=?
 point<=?
 pos<?
 pos=?
 pos<=?
 point-clamp)

(struct point (line col) #:transparent)

;;; ---------- 比较 ----------
;; 少构造 point 的裸比较，给「还没夹紧的输入」这类场景用。
;; 位置比较只有这一份实现，point<？/point<=? 是它的 point 包装。

(define (pos<? l1 c1 l2 c2)
  (or (< l1 l2) (and (= l1 l2) (< c1 c2))))

(define (pos=? l1 c1 l2 c2)
  (and (= l1 l2) (= c1 c2)))

(define (pos<=? l1 c1 l2 c2)
  (or (pos<? l1 c1 l2 c2) (pos=? l1 c1 l2 c2)))

(define (point<? a b)
  (pos<? (point-line a) (point-col a) (point-line b) (point-col b)))

(define (point=? a b)
  (pos=? (point-line a) (point-col a) (point-line b) (point-col b)))

(define (point<=? a b)
  (pos<=? (point-line a) (point-col a) (point-line b) (point-col b)))

;;; ---------- 夹紧 ----------
;; 把 point 夹到合法域：行 ∈ [0, line-count)，列 ∈ [0, 第 line 行长]。
;;   line-count  : nat ≥ 1          总行数
;;   line-length : nat -> nat       第 i 行的长度（字符数）
(define (point-clamp p line-count line-length)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'point-clamp "line-count must be >= 1, got ~a" line-count))
  (define l (max 0 (min (point-line p) (sub1 line-count))))
  (point l (max 0 (min (point-col p) (line-length l)))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (check-equal? (point 2 3) (point 2 3))
  (check-true  (point<? (point 1 9) (point 2 0)))
  (check-true  (point<? (point 1 1) (point 1 2)))
  (check-false (point<? (point 1 2) (point 1 2)))
  (check-true  (point<=? (point 1 2) (point 1 2)))
  (check-true  (point=? (point 4 0) (point 4 0)))
  (check-false (point=? (point 4 0) (point 0 4)))

  ;; 裸比较：比较器只有一份实现
  (check-true (pos<? 0 5 1 0))
  (check-true (pos=? 3 2 3 2))
  (check-true (pos<=? 3 2 3 2))
  (check-false (pos<=? 3 3 3 2))

  ;; 夹紧：行越界、列越界分别夹；合法域内不动
  (define n 3)
  (define (len l) (list-ref '(2 3 5) l))
  (check-equal? (point-clamp (point 1 1) n len) (point 1 1))
  (check-equal? (point-clamp (point 9 9) n len) (point 2 5))
  (check-equal? (point-clamp (point -2 -2) n len) (point 0 0))
  (check-equal? (point-clamp (point 1 99) n len) (point 1 3))

  (displayln "point.rkt: all tests passed"))

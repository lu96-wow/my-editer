#lang racket

;;; cursor.rkt —— 位置代数
;;;
;;; 设计：一个位置是一对 (line, col)，0-based。
;;; 它不知道所在行有多长、也不知道有没有文本。
;;; 合法性（col 不越界）由调用者用 cursor-clamp 保证。

(provide
 (struct-out cursor)
 cursor<?
 cursor=?
 cursor<=?
 cursor-clamp)

(struct cursor (line col) #:transparent)

;; 字典序：先行后列
(define (cursor<? a b)
  (or (< (cursor-line a) (cursor-line b))
      (and (= (cursor-line a) (cursor-line b))
           (< (cursor-col a) (cursor-col b)))))

(define (cursor=? a b)
  (and (= (cursor-line a) (cursor-line b))
       (= (cursor-col a) (cursor-col b))))

(define (cursor<=? a b)
  (or (cursor<? a b) (cursor=? a b)))

;; 夹紧到合法范围。
;;   line-count : nat >= 1        总行数
;;   line-length : nat -> nat     第 i 行的长度
(define (cursor-clamp c line-count line-length)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'cursor-clamp "line-count must be >= 1, got ~a" line-count))
  (define l (max 0 (min (cursor-line c) (sub1 line-count))))
  (define n (line-length l))
  (cursor l (max 0 (min (cursor-col c) n))))
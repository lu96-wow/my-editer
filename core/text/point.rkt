#lang racket

;;; point.rkt —— 位置代数
;;;
;;; 设计：一个位置是一对 (line, col)，0-based。
;;; 它不知道所在行有多长、也不知道有没有文本。
;;; 合法性（col 不越界）由调用者用 point-clamp 保证。

(provide
 (struct-out point)
 point<?
 point=?
 point<=?
 point-clamp)

(struct point (line col) #:transparent)

;; 字典序：先行后列
(define (point<? a b)
  (or (< (point-line a) (point-line b))
      (and (= (point-line a) (point-line b))
           (< (point-col a) (point-col b)))))

(define (point=? a b)
  (and (= (point-line a) (point-line b))
       (= (point-col a) (point-col b))))

(define (point<=? a b)
  (or (point<? a b) (point=? a b)))

;; 夹紧到合法范围。
;;   line-count : nat >= 1        总行数
;;   line-length : nat -> nat     第 i 行的长度
(define (point-clamp c line-count line-length)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'point-clamp "line-count must be >= 1, got ~a" line-count))
  (define l (max 0 (min (point-line c) (sub1 line-count))))
  (define n (line-length l))
  (point l (max 0 (min (point-col c) n))))
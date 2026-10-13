#lang racket

(require "point.rkt")

;;; base/range.rkt —— 点区间 [start, end)
;;;
;;; 两个 point 组成的**半开区间**，构造时归一为 start ≤ end。
;;; 它是纯位置结构：不含文本、不含文档，可判等。
;;;
;;; change（见 change.rkt）用两个 range 描述一次编辑的「前 / 后」；
;;; document-range-text 用 range 从文档里取一段文本。

(provide
 ;; ---------- 类型 / 构造 ----------
 (struct-out range)
 range-of range-empty? range-normalize

 ;; ---------- 比较 ----------
 range=?)

(struct range (start end) #:transparent)

;; 构造：两端乱序自动归一为 start ≤ end。
(define (range-of a b) (if (point<=? a b) (range a b) (range b a)))

(define (range-empty? r) (point=? (range-start r) (range-end r)))

(define (range-normalize r) (range-of (range-start r) (range-end r)))

(define (range=? a b)
  (and (point=? (range-start a) (range-start b))
       (point=? (range-end a) (range-end b))))

#lang racket

(require "track.rkt" "line.rkt")

;;; base/point.rkt —— 位置 (line, col)：值、比较、夹紧、**字符级**导航
;;;
;;; 文档按「行 + 行内格」寻址，所以位置就是 (行, 格号)，全 0-based。
;;; point **不知道**它所在行多长；合法性由 point-clamp 保证。
;;;
;;; 这里只做**字符级**导航（左/右/行首/行尾）：只需一行文本，与显示模式无关。
;;; **上/下是视觉行移动**，依赖折行宽度与模式，放在 view/base/viewport + layout。

(provide
 ;; ---------- 类型 ----------
 (struct-out point)

 ;; ---------- 比较 ----------
 point<? point=? point<=?
 pos<? pos=? pos<=?

 ;; ---------- 夹紧 ----------
 point-clamp

 ;; ---------- 字符级导航 ----------
 point-left point-right point-home point-end)

(struct point (line col) #:transparent)
;; line / col : nat（0-based）

;;; ---------- 比较 ----------

(define (pos<? l1 c1 l2 c2) (or (< l1 l2) (and (= l1 l2) (< c1 c2))))
(define (pos=? l1 c1 l2 c2) (and (= l1 l2) (= c1 c2)))
(define (pos<=? l1 c1 l2 c2) (or (pos<? l1 c1 l2 c2) (pos=? l1 c1 l2 c2)))

(define (point<? a b) (pos<? (point-line a) (point-col a) (point-line b) (point-col b)))
(define (point=? a b) (pos=? (point-line a) (point-col a) (point-line b) (point-col b)))
(define (point<=? a b) (pos<=? (point-line a) (point-col a) (point-line b) (point-col b)))

;;; ---------- 夹紧 ----------

(define (point-clamp p line-count line-length)
  (unless (and (exact-nonnegative-integer? line-count) (>= line-count 1))
    (error 'point-clamp "line-count must be >= 1, got ~a" line-count))
  (define l (max 0 (min (point-line p) (sub1 line-count))))
  (point l (max 0 (min (point-col p) (line-length l)))))

;;; ---------- 字符级导航 ----------

(define (point-left t p)
  (define l (point-line p)) (define c (point-col p))
  (cond [(> c 0) (point l (sub1 c))]
        [(> l 0) (point (sub1 l) (line-length (track-ref t (sub1 l))))]
        [else p]))

(define (point-right t p)
  (define l (point-line p)) (define c (point-col p))
  (cond [(< c (line-length (track-ref t l))) (point l (add1 c))]
        [(< l (sub1 (track-length t))) (point (add1 l) 0)]
        [else p]))

(define (point-home _t p) (point (point-line p) 0))
(define (point-end t p)
  (point (point-line p) (line-length (track-ref t (point-line p)))))

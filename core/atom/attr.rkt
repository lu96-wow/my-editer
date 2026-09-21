#lang racket

(require "point.rkt" rackunit)

;;; atom/attr.rkt —— 属性变更原子（attr-desc）
;;;
;;; 一条 attr-desc = 「对某一行内区间 [start,end) 上的某个 key 做 set/remove」。
;;; 与 edit-desc 并列：edit-desc 改文本，attr-desc 改属性；两者都只描述**变更**，
;;; 不含旧值/旧状态，因此可以打包进 change、进账本、可重放。
;;;
;;; 约束（由施加方校验，见 doc/buffer.rkt）：
;;;   · start/end 必须**同一行**（属性是行内区间）；
;;;   · 半开 [start,end)；零宽 = no-op；
;;;   · 坐标是「施加前」的属性坐标。
;;;
;;; 本原子不认识 attrs 集合（那是 unit/attrs.rkt），只定义变更的形状与访问。

(provide
 (struct-out attr-desc)
 attr-set
 attr-del
 attr-desc-empty?)

;;; ---------- 数据 ----------

(struct attr-desc (start end key op val) #:transparent)
;; start/end : point     同一行，半开 [start,end)
;; key       : symbol
;; op        : 'set | 'remove
;; val       : any/c     仅 op = 'set 时有效

(define (attr-set start end key val) (attr-desc start end key 'set val))
(define (attr-del start end key)     (attr-desc start end key 'remove #f))

;; 零宽属性区间没有合法解释为「标注某段」，唯一语义是 no-op。
(define (attr-desc-empty? d) (point=? (attr-desc-start d) (attr-desc-end d)))

;;; ---------- 测试 ----------

(module+ test
  (define p (lambda (l c) (point l c)))
  (check-equal? (attr-set (p 0 1) (p 0 3) 'face 'bold)
                (attr-desc (p 0 1) (p 0 3) 'face 'set 'bold))
  (check-equal? (attr-desc-op (attr-del (p 0 1) (p 0 3) 'face)) 'remove)
  (check-true (attr-desc-empty? (attr-set (p 0 2) (p 0 2) 'face 'bold)))
  (check-false (attr-desc-empty? (attr-set (p 0 1) (p 0 2) 'face 'bold)))
  (displayln "attr.rkt: all tests passed"))

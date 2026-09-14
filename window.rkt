#lang racket

(require "cursor.rkt" "buffer.rkt" rackunit)

;;; window.rkt —— 视图状态
;;;
;;; 一个 buffer 可以显示在多个 window，每个 window 有独立的
;;; 滚动位置和渲染缓存。window 不拥有文本，只拥有显示状态。
;;;
;;; render-cache 由 render.rkt 解释；本文件只负责存取。

(provide
 (struct-out window)
 window-open
 window-set-buffer
 window-set-top
 window-scroll
 window-set-render-cache
 window-set-last-tick
 window-visible-range)

(struct window
  (buffer       ; buffer.rkt
   top-line     ; nat            顶行在 buffer 中的行号
   height       ; nat            可见行数
   render-cache ; (or/c vector? #f)
   last-tick)   ; nat            上次渲染时 buffer 的 tick
  #:transparent)

;;; ---------- 构造 ----------

(define (window-open b [height 24])
  (unless (and (exact-nonnegative-integer? height) (>= height 1))
    (error 'window-open "height must be >= 1, got ~a" height))
  (window b 0 height #f (buffer-tick b)))

;;; ---------- 存取 ----------

(define (window-set-buffer w b)
  (struct-copy window w [buffer b]))

(define (window-set-top w n)
  (struct-copy window w [top-line (max 0 n)]))

(define (window-scroll w delta)
  (struct-copy window w [top-line (max 0 (+ (window-top-line w) delta))]))

(define (window-set-render-cache w c)
  (struct-copy window w [render-cache c]))

(define (window-set-last-tick w t)
  (struct-copy window w [last-tick t]))

;;; 当前可见行号范围 [start, end)，end 会夹到 buffer 末尾。
(define (window-visible-range w)
  (define n (buffer-line-count (window-buffer w)))
  (define start (min (window-top-line w) (sub1 n)))
  (define end   (min n (+ start (window-height w))))
  (values start end))

;;; ---------- 测试 ----------

(module+ test
  (define b (buffer-open "a\nb\nc\nd\ne"))
  (define w (window-open b 2))

  (check-equal? (window-top-line w) 0)
  (check-equal? (window-height w) 2)
  (check-equal? (window-last-tick w) 0)
  (check-false (window-render-cache w))

  ;; visible range
  (define-values (s1 e1) (window-visible-range w))
  (check-equal? s1 0)
  (check-equal? e1 2)

  ;; scroll
  (define w2 (window-scroll w 2))
  (check-equal? (window-top-line w2) 2)
  (define-values (s2 e2) (window-visible-range w2))
  (check-equal? s2 2)
  (check-equal? e2 4)

  ;; scroll 下界保护
  (check-equal? (window-top-line (window-scroll w -5)) 0)

  ;; visible range 夹到末尾
  (define w3 (window-set-top w 4))
  (define-values (s3 e3) (window-visible-range w3))
  (check-equal? s3 4)
  (check-equal? e3 5)

  (displayln "window.rkt: all tests passed"))
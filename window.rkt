#lang racket

(require "cursor.rkt" "buffer.rkt" rackunit)

;;; window.rkt —— 视图状态（纯视图，不持有文本）
;;;
;;; 一个 buffer 可以显示在多个 window，每个 window 有独立的
;;; 滚动位置（top-line / left-col）和渲染缓存。
;;; buffer 是文档（含 point / dirty），window 只是「怎么看它」，
;;; window 里的 buffer 字段是共享引用（持久化结构天然安全）。

(provide
 (struct-out window)
 window-open
 window-set-buffer
 window-set-top
 window-set-left
 window-set-size
 window-scroll
 window-hscroll
 window-set-render-cache
 window-set-last-tick
 window-visible-range)

(struct window
  (buffer       ; buffer.rkt       只读引用，window 不改 buffer 内容
   top-line     ; nat              顶行在 buffer 中的行号（0-based）
   left-col     ; nat              左列（显示列，0-based，宽字符后）
   height       ; nat              可见行数
   width        ; nat              可见列数
   render-cache ; (or/c vector? #f)
   last-tick)   ; nat              上次渲染时 buffer 的 tick
  #:transparent)

(define (window-open b [height 24] [width 80])
  (unless (and (exact-nonnegative-integer? height) (>= height 1))
    (error 'window-open "height must be >= 1, got ~a" height))
  (unless (and (exact-nonnegative-integer? width) (>= width 1))
    (error 'window-open "width must be >= 1, got ~a" width))
  (window b 0 0 height width #f (buffer-tick b)))

(define (window-set-buffer w b) (struct-copy window w [buffer b]))
(define (window-set-top w n)    (struct-copy window w [top-line (max 0 n)]))
(define (window-set-left w n)   (struct-copy window w [left-col (max 0 n)]))

(define (window-set-size w height width)
  (struct-copy window w
    [height (max 1 height)]
    [width  (max 1 width)]))

(define (window-scroll w delta)
  (struct-copy window w [top-line (max 0 (+ (window-top-line w) delta))]))

(define (window-hscroll w delta)
  (struct-copy window w [left-col (max 0 (+ (window-left-col w) delta))]))

(define (window-set-render-cache w c) (struct-copy window w [render-cache c]))
(define (window-set-last-tick w t)    (struct-copy window w [last-tick t]))

;; 当前可见行号范围 [start, end)，end 夹到 buffer 末尾。
(define (window-visible-range w)
  (define n (buffer-line-count (window-buffer w)))
  (define start (min (window-top-line w) (sub1 n)))
  (define end   (min n (+ start (window-height w))))
  (values start end))

(module+ test
  (define b (buffer-open "a\nb\nc\nd\ne"))
  (define w (window-open b 2))

  (check-equal? (window-top-line w) 0)
  (check-equal? (window-left-col w) 0)
  (check-equal? (window-height w) 2)
  (check-equal? (window-width w) 80)
  (check-equal? (window-last-tick w) 0)
  (check-false (window-render-cache w))

  (define-values (s1 e1) (window-visible-range w))
  (check-equal? s1 0)
  (check-equal? e1 2)

  (define w2 (window-scroll w 2))
  (check-equal? (window-top-line w2) 2)
  (define-values (s2 e2) (window-visible-range w2))
  (check-equal? s2 2)
  (check-equal? e2 4)

  (check-equal? (window-top-line (window-scroll w -5)) 0)

  (define w3 (window-set-top w 4))
  (define-values (s3 e3) (window-visible-range w3))
  (check-equal? s3 4)
  (check-equal? e3 5)

  ;; 水平滚动 + 尺寸
  (define w4 (window-hscroll (window-set-left w 3) 2))
  (check-equal? (window-left-col w4) 5)
  (check-equal? (window-hscroll w -10) (window-set-left w 0))
  (define w5 (window-set-size w 30 100))
  (check-equal? (window-height w5) 30)
  (check-equal? (window-width w5) 100)

  (displayln "window.rkt: all tests passed"))

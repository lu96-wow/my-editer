#lang racket

(require "cursor.rkt" "buffer.rkt" rackunit)

;;; window.rkt —— 视图状态（纯视图，不持有文本）
;;;
;;; buffer 是文档（含 point / dirty），window 只是「怎么看它」。
;;; 只存滚动位置与尺寸，不缓存任何渲染结果（渲染见 view / paint）。
;;;
;;; mode 决定两种显示方式：
;;;   'clip —— 硬裁剪：每 buffer 行 = 一条屏幕行，水平滚动用 left-col
;;;   'wrap —— 折行：长行按 width 折成多段，滚动用 top-line + top-seg

(provide
 (struct-out window)
 window-open
 window-set-buffer
 window-set-mode
 window-set-top
 window-set-left
 window-set-top-seg
 window-set-size
 window-scroll
 window-hscroll)

(struct window
  (buffer   ; buffer.rkt     只读引用，window 不改 buffer 内容
   mode     ; 'clip | 'wrap
   top-line ; nat            clip：顶 buffer 行；wrap：顶部所在 buffer 行
   left-col ; nat            clip：水平滚动列；wrap：恒 0
   top-seg  ; nat            wrap：顶部行的第几个折行段；clip：恒 0
   height   ; nat            可见行数
   width)   ; nat            可见列数
  #:transparent)

(define (window-open b [height 24] [width 80])
  (unless (and (exact-nonnegative-integer? height) (>= height 1))
    (error 'window-open "height must be >= 1, got ~a" height))
  (unless (and (exact-nonnegative-integer? width) (>= width 1))
    (error 'window-open "width must be >= 1, got ~a" width))
  (window b 'clip 0 0 0 height width))

(define (window-set-buffer w b)   (struct-copy window w [buffer b]))
(define (window-set-mode w m)     (struct-copy window w [mode m]))
(define (window-set-top w n)      (struct-copy window w [top-line (max 0 n)]))
(define (window-set-left w n)     (struct-copy window w [left-col (max 0 n)]))
(define (window-set-top-seg w n)  (struct-copy window w [top-seg (max 0 n)]))
(define (window-set-size w height width)
  (struct-copy window w [height (max 1 height)] [width (max 1 width)]))

;; clip 垂直滚动（按 buffer 行）；wrap 的视觉行滚动见 view.rkt
(define (window-scroll w delta)
  (struct-copy window w [top-line (max 0 (+ (window-top-line w) delta))]))

(define (window-hscroll w delta)
  (struct-copy window w [left-col (max 0 (+ (window-left-col w) delta))]))

(module+ test
  (define b (buffer-open "a\nb\nc\nd\ne"))
  (define w (window-open b 2))

  (check-equal? (window-mode w) 'clip)
  (check-equal? (window-top-line w) 0)
  (check-equal? (window-left-col w) 0)
  (check-equal? (window-top-seg w) 0)
  (check-equal? (window-height w) 2)
  (check-equal? (window-width w) 80)

  (check-equal? (window-top-line (window-scroll w 2)) 2)
  (check-equal? (window-top-line (window-scroll w -5)) 0)
  (check-equal? (window-top-line (window-set-top w 4)) 4)

  (define w4 (window-hscroll (window-set-left w 3) 2))
  (check-equal? (window-left-col w4) 5)
  (check-equal? (window-hscroll w -10) (window-set-left w 0))

  (define w5 (window-set-size w 30 100))
  (check-equal? (window-height w5) 30)
  (check-equal? (window-width w5) 100)
  (check-equal? (window-mode (window-set-mode w 'wrap)) 'wrap)
  (check-equal? (window-top-seg (window-set-top-seg w 3)) 3)

  (displayln "window.rkt: all tests passed"))

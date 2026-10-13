#lang racket

;;; edit4/config/floats.rkt —— 浮窗声明（纯数据）
;;;
;;;   (name (rel h v dx dy) (want-w want-h))
;;;   rel : screen | wid（锚到某个平铺窗）；h : left|right|center；v : top|bottom|center
;;;
;;; 浮窗也是窗口（opaque id）+ 视图（vid），几何由 anchor 决定、画在最上（列表头）。
;;; float-open NAME 用这里的几何；没声明的名字退化成右下角默认尺寸。

(provide float-specs float-spec)

(define float-specs
  '((tree    (screen left  top    0 0) (30 16))
    (buffers (screen left  top    0 0) (30 16))
    (log     (screen right bottom 2 2) (46 10))))

(define (float-spec name)
  (for/first ([s (in-list float-specs)] #:when (eq? name (car s))) (cdr s)))

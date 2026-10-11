#lang racket

;;; edit3/config/floats.rkt —— 浮窗声明（**纯数据**，不 require 实现）
;;;
;;;   (name (anchor role h v dx dy) (want-w want-h))
;;;
;;;   role : screen | focused | editor | (panel id) | 显式 wid
;;;   h    : left | right | center
;;;   v    : top  | bottom | center
;;;
;;; 浮窗也是窗口（wid）+ 视图（vid），只是几何由 anchor 决定、画在最上（列表头）。
;;; float-open NAME 会用这里的几何；没声明的名字退化成右下角默认尺寸。

(provide float-specs)

(define float-specs
  '((tree    (anchor screen left  top    0 0)  (30 16))
    (buffers (anchor screen left  top    0 0)  (30 16))
    (log     (anchor screen right bottom 2 2)  (46 10))))

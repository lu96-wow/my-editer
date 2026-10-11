#lang racket

;;; config/floats.rkt —— 浮窗声明（**纯数据**，不 require 实现）
;;;
;;;   (name (anchor role h v dx dy) (want-w want-h))
;;;
;;;   role : screen | focused | editor | (panel id) | 显式 wid
;;;          （写「角色」，打开时由 core 解析成 wid 再存进节点；layout 只认 wid）
;;;   h    : left | right | center | stretch
;;;   v    : top  | bottom | center | stretch
;;;
;;; 浮窗也是窗口（wid）+ 视图（vid），只是几何由 anchor 决定、画在最上（stack 头）。
;;; float-open NAME 会用这里的几何；没声明的名字退化成右下角默认尺寸。

(provide float-specs)

(define float-specs
  '((tree    (anchor screen left  top    0 0)  (30 16))
    (buffers (anchor screen left  top    0 0)  (30 16))
    (log     (anchor screen right bottom 2 2)  (46 10))))

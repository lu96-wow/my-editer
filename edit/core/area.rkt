#lang racket

;;; edit/core/area.rkt —— 矩形区域（屏幕坐标）
;;;
;;; 布局核心（edit/core/layout.rkt）用的最小几何值。

(provide (struct-out area))

(struct area (x y w h) #:transparent)

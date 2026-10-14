#lang racket

;;; edit-tui/theme/frame.rkt —— 框架主题
;;;
;;; 布局面板的边框 face：窗口 / 聚焦 / 浮窗。
;;; 键就是 layout panel 的 face 标签，core-render/border.rkt 画边框时带上。

(require "theme.rkt")

(provide frame-theme)

(define frame-theme
  (list
   (list 'window-border  (style (rgb 90 96 110) #f '()))
   (list 'focused-border (style (rgb 120 180 240) #f '()))
   (list 'float-border   (style (rgb 190 150 240) #f '()))))

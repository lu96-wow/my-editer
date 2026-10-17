#lang racket

;;; edit-tui/theme/frame.rkt —— 框架主题
;;;
;;; 布局面板的边框 face：窗口 / 聚焦 / 浮窗。
;;; 键就是 core panel 的 face 标签，core 画边框时带上。

(require "theme.rkt")

(provide frame-theme)

(define frame-theme
  (list
   (list 'window-border  (style (rgb 90 96 110) #f '()))
   (list 'focused-border (style (rgb 120 180 240) #f '()))
   (list 'float-border   (style (rgb 190 150 240) #f '()))
   ;; 资源列表面板
   (list 'resource-document (style (rgb 120 220 120) #f '()))   ; 绿色：document
   (list 'resource-view     (style (rgb 150 190 230) #f '()))   ; 蓝色：view
   (list 'resource-focus    (style (rgb 120 180 240) #f '()))
   (list 'resource-pending  (style (rgb 240 160 120) #f '()))))

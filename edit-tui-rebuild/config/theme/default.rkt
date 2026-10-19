#lang racket

;;; edit-tui-rebuild/config/theme/default.rkt —— 默认主题
;;;
;;; require 即安装（顶层求值）。
;;; 换主题 = 换 require 的 config/theme/*.rkt。

(require "../../render/theme.rkt")

(provide default-theme)

(define default-theme
  (list
   ;; 基础
   (list 'fg-default   (style #f #f '()))
   (list 'bg-default   (style #f #f '()))
   (list 'fg-dim       (style (rgb 120 120 130) #f '()))
   (list 'line-number  (style (rgb 120 120 130) #f '()))
   (list 'bold         (style #f #f '(bold)))
   (list 'dim          (style #f #f '(dim)))
   (list 'italic       (style #f #f '(italic)))
   (list 'underline    (style #f #f '(underline)))
   (list 'blink        (style #f #f '(blink)))

   ;; 边框
   (list 'window-border   (style (rgb 105 112 128) #f '()))
   (list 'focused-border  (style (rgb 120 180 240) #f '()))
   (list 'float-border    (style (rgb 190 150 240) #f '()))

   ;; chrome / 资源
   (list 'status-bar        (style (rgb 225 225 225) (rgb 40 44 52) '()))
   (list 'status-mode       (style (rgb 120 210 130) #f '(bold)))
   (list 'status-dirty      (style (rgb 230 160 90) #f '(bold)))
   (list 'message           (style (rgb 230 160 90) #f '()))
   (list 'input             (style #f #f '()))
   (list 'resource-document (style (rgb 200 200 200) #f '()))
   (list 'resource-view     (style (rgb 140 160 190) #f '()))
   (list 'resource-focus    (style (rgb 120 210 130) #f '(bold)))
   (list 'resource-pending  (style (rgb 230 160 90) #f '(bold)))

   ;; overlay
   (list 'cursor    (style #f #f '(reverse)))
   (list 'selection (style #f (rgb 60 70 90) '()))))

(define-theme! default-theme)

#lang racket

;;; edit-tui/theme/core.rkt —— 渲染核心主题
;;;
;;; 正文 / 行号 / 语法 / 括号背景 / 装饰背景 / 属性 / 光标 / 选区。
;;; 键就是 core-render 渲染时会遇到的 face 符号。

(require "theme.rkt")

(provide core-theme)

(define core-theme
  (list
   ;; 行号 / 正文 / 属性
   (list 'fg-default      (style (rgb 200 200 200) #f '()))
   (list 'bg-default      (style #f (rgb 20 22 28) '()))
   (list 'line-number     (style (rgb 128 128 140) #f '()))
   (list 'fg-dim          (style (rgb 120 120 130) #f '()))
   (list 'bold            (style #f #f '(bold)))
   (list 'dim             (style #f #f '(dim)))
   (list 'italic          (style #f #f '(italic)))
   (list 'underline       (style #f #f '(underline)))
   (list 'blink           (style #f #f '(blink)))

   ;; 语法
   (list 'fg-syntax-def     (style (rgb 120 180 240) #f '()))
   (list 'fg-syntax-control (style (rgb 230 150 180) #f '()))
   (list 'fg-syntax-macro   (style (rgb 190 150 240) #f '()))
   (list 'fg-syntax-binding (style (rgb 235 190 110) #f '()))
   (list 'fg-syntax-module  (style (rgb 120 200 200) #f '()))
   (list 'fg-syntax-string  (style (rgb 190 220 140) #f '()))
   (list 'fg-syntax-comment (style (rgb 120 120 130) #f '(italic)))
   (list 'fg-syntax-number  (style (rgb 200 170 240) #f '()))
   ;; 括号深度底色（plugins/highlight/depth-plugin.rkt 写的就是 bg 分量）
   (list 'bg-depth-1       (style #f (rgb 26 32 44) '()))
   (list 'bg-depth-2       (style #f (rgb 34 42 58) '()))
   (list 'bg-depth-3       (style #f (rgb 44 54 72) '()))

   ;; 括号深度（背景）
   (list 'bg-bracket-0 (style #f (rgb 36 40 58) '()))
   (list 'bg-bracket-1 (style #f (rgb 28 47 49) '()))
   (list 'bg-bracket-2 (style #f (rgb 48 46 30) '()))
   (list 'bg-bracket-3 (style #f (rgb 30 49 40) '()))

   ;; 装饰背景
   (list 'bg-word-mark (style #f (rgb 60 70 90) '()))
   (list 'bg-sync-mark (style #f (rgb 60 95 80) '()))

   ;; overlay（patch.rkt 的语义角色）
   (list 'cursor           (style #f #f '(reverse)))
   (list 'cursor-secondary (style #f #f '(underline)))
   (list 'selection        (style #f (rgb 60 70 90) '()))))

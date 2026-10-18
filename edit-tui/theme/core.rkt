#lang racket

;;; edit-tui/theme/core.rkt —— 渲染核心主题
;;;
;;; 颜色与 history/edit4/config/palette.rkt 同步。
;;; 键就是 core-render / 插件渲染时会遇到的 face 符号；只在这里写具体颜色。

(require "theme.rkt")

(provide core-theme)

(define core-theme
  (list
   ;; 正文 / 行号 / 属性（edit4 的 default 是终端默认色）
   (list 'fg-default      (style #f #f '()))
   (list 'bg-default      (style #f #f '()))
   (list 'line-number     (style (rgb 120 120 130) #f '()))
   (list 'fg-dim          (style (rgb 120 120 130) #f '()))
   (list 'bold            (style #f #f '(bold)))
   (list 'dim             (style #f #f '(dim)))
   (list 'italic          (style #f #f '(italic)))
   (list 'underline       (style #f #f '(underline)))
   (list 'blink           (style #f #f '(blink)))

   ;; 语法前景（与 edit4 完全一致）
   (list 'fg-syntax-def     (style (rgb 120 180 240) #f '()))
   (list 'fg-syntax-control (style (rgb 230 150 180) #f '()))
   (list 'fg-syntax-macro   (style (rgb 190 150 240) #f '()))
   (list 'fg-syntax-binding (style (rgb 235 190 110) #f '()))
   (list 'fg-syntax-module  (style (rgb 120 200 200) #f '()))
   (list 'fg-syntax-string  (style (rgb 190 220 140) #f '()))
   (list 'fg-syntax-comment (style (rgb 120 120 130) #f '(italic)))
   (list 'fg-syntax-number  (style (rgb 200 170 240) #f '()))

   ;; 同词着色（edit4 'word 调色板，12 色）
   (list 'fg-word-0  (style (rgb 230 194 158) #f '()))
   (list 'fg-word-1  (style (rgb 216 204 152) #f '()))
   (list 'fg-word-2  (style (rgb 184 210 160) #f '()))
   (list 'fg-word-3  (style (rgb 162 212 172) #f '()))
   (list 'fg-word-4  (style (rgb 152 214 202) #f '()))
   (list 'fg-word-5  (style (rgb 142 206 226) #f '()))
   (list 'fg-word-6  (style (rgb 150 196 236) #f '()))
   (list 'fg-word-7  (style (rgb 166 182 236) #f '()))
   (list 'fg-word-8  (style (rgb 196 172 234) #f '()))
   (list 'fg-word-9  (style (rgb 206 172 226) #f '()))
   (list 'fg-word-10 (style (rgb 188 178 214) #f '()))
   (list 'fg-word-11 (style (rgb 178 198 214) #f '()))

   ;; 括号深度背景（edit4 'bracket 调色板，8 色）
   (list 'bg-depth-1 (style #f (rgb 36 40 58) '()))
   (list 'bg-depth-2 (style #f (rgb 28 47 49) '()))
   (list 'bg-depth-3 (style #f (rgb 48 46 30) '()))
   (list 'bg-depth-4 (style #f (rgb 30 49 40) '()))
   (list 'bg-depth-5 (style #f (rgb 42 34 58) '()))
   (list 'bg-depth-6 (style #f (rgb 34 44 58) '()))
   (list 'bg-depth-7 (style #f (rgb 38 48 34) '()))
   (list 'bg-depth-8 (style #f (rgb 44 38 54) '()))


   ;; 装饰背景
   (list 'bg-word-mark (style #f (rgb 60 70 90) '()))
   (list 'bg-sync-mark (style #f (rgb 60 95 80) '()))

   ;; chrome / 面板
   (list 'status-bar    (style (rgb 225 225 225) (rgb 40 44 52) '()))
   (list 'status-mode   (style (rgb 120 210 130) #f '(bold)))
   (list 'status-dirty  (style (rgb 230 160 90) #f '(bold)))
   (list 'message       (style (rgb 230 160 90) #f '()))
   (list 'input         (style #f #f '()))
   (list 'log           (style (rgb 235 188 110) #f '()))
   (list 'docs          (style (rgb 200 212 235) (rgb 30 34 44) '()))
   (list 'docs-dim      (style (rgb 145 155 180) (rgb 30 34 44) '()))
   (list 'complete          (style (rgb 220 220 220) (rgb 40 44 52) '()))
   (list 'complete-selected (style (rgb 20 20 20) (rgb 120 180 240) '()))

   ;; overlay（patch.rkt 的语义角色）
   (list 'cursor           (style #f #f '(reverse)))
   (list 'cursor-secondary (style #f #f '(underline)))
   (list 'selection        (style #f (rgb 60 70 90) '()))))

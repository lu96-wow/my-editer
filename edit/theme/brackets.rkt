#lang racket

;;; edit/theme/brackets.rkt —— 括号深度背景调色板（纯数据）
;;;
;;; palette-bg 'bracket level 按这里取模取**背景**色：不同嵌套层不同底色。
;;; level = 匹配对的最内层包围层（最外层 = 0）。

(require "style.rkt")

(provide bracket-palettes)

(define bracket-palettes
  (hash 'bracket (vector (rgb 70 56 90)      ; 深紫
                         (rgb 44 74 66)      ; 深绿
                         (rgb 84 66 44)      ; 深黄
                         (rgb 52 62 92))))   ; 深蓝

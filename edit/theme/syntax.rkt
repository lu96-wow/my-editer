#lang racket

;;; edit/theme/syntax.rkt —— 语法高亮调色板（纯数据）
;;;
;;; palette-color 'keyword index 按这里的顺序取模取色：相邻关键字拿相邻色号，
;;; 同一个关键字任何时候同色。「哪些文件参与」由插件 applies? 决定。

(require "style.rkt")

(provide syntax-palettes)

(define syntax-palettes
  (hash 'keyword (vector (rgb 198 120 221)     ; 紫
                         (rgb 97 175 239)      ; 蓝
                         (rgb 152 195 121)     ; 绿
                         (rgb 229 192 123)     ; 黄
                         (rgb 224 108 117)     ; 红
                         (rgb 86 182 194))))   ; 青

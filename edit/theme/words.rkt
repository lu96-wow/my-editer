#lang racket

;;; edit/theme/words.rkt —— 词高亮调色板（纯数据）
;;;
;;; palette-color 'word index 按这里顺序取模取色：同词同号 → 同色。
;;; 色号由插件按首次出现分配，与具体词无关。

(require "style.rkt")

(provide word-palettes)

(define word-palettes
  (hash 'word (vector (rgb 198 120 221)
                      (rgb 97 175 239)
                      (rgb 152 195 121)
                      (rgb 229 192 123)
                      (rgb 224 108 117)
                      (rgb 86 182 194)
                      (rgb 170 150 230)
                      (rgb 130 200 160))))

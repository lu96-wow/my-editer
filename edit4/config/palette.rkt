#lang racket

;;; edit4/config/palette.rkt —— 主题调色板（纯数据，不 require 实现）
;;;
;;; 命名 face（符号）→ style；调色板（按位置取色）给 palette-color / palette-bg。
;;; 把 style 翻成 ANSI 字节在 view/theme.rkt。

(provide (struct-out style) rgb palette theme-ref palettes palette-ref)

(struct style (fg bg attrs) #:transparent)
;; fg/bg = #f | (rgb r g b) | 0..255；attrs = (listof bold|dim|italic|underline)

(define (rgb r g b) (list 'rgb r g b))

(define palette
  (hash
   'default        (style #f #f '())
   'dim            (style (rgb 120 120 130) #f '())
   'bold           (style #f #f '(bold))
   'window-border  (style (rgb 105 112 128) #f '())
   'status-bar     (style (rgb 225 225 225) (rgb 40 44 52) '())
   'status-mode    (style (rgb 120 210 130) #f '(bold))
   'status-dirty   (style (rgb 230 160 90) #f '(bold))
   'message        (style (rgb 230 160 90) #f '())
   'input          (style #f #f '())
   'log            (style (rgb 235 188 110) #f '())
   'docs           (style (rgb 200 212 235) (rgb 30 34 44) '())
   'docs-dim       (style (rgb 145 155 180) (rgb 30 34 44) '())
   ;; 文件树
   'tree-dir       (style (rgb 120 180 240) #f '())
   'tree-file      (style (rgb 200 200 200) #f '())
   'tree-hidden    (style (rgb 120 120 130) #f '())
   'tree-open      (style (rgb 120 210 130) #f '(bold))
   'buf-current    (style (rgb 120 210 130) #f '(bold))
   'buf-file       (style (rgb 200 200 200) #f '())
   'buf-untitled   (style (rgb 170 170 170) #f '())
   'buf-view       (style (rgb 140 160 190) #f '())
   'buf-view-idle  (style (rgb 120 120 130) #f '())
   'buf-dirty      (style (rgb 230 160 90) #f '(bold))
   ;; 语法高亮
   'syntax-def     (style (rgb 120 180 240) #f '())
   'syntax-control (style (rgb 230 150 180) #f '())
   'syntax-macro   (style (rgb 190 150 240) #f '())
   'syntax-binding (style (rgb 235 190 110) #f '())
   'syntax-module  (style (rgb 120 200 200) #f '())
   'syntax-string  (style (rgb 190 220 140) #f '())
   'syntax-comment (style (rgb 120 120 130) #f '(italic))
   'syntax-number  (style (rgb 200 170 240) #f '())
   'word-mark      (style #f (rgb 60 70 90) '())
   'sync-mark      (style #f (rgb 60 95 80) '())
   'complete          (style (rgb 220 220 220) (rgb 40 44 52) '())
   'complete-selected (style (rgb 20 20 20) (rgb 120 180 240) '())))

(define (theme-ref name) (hash-ref palette name #f))

(define palettes
  (hash
   'keyword (list (rgb 120 180 240) (rgb 230 150 180) (rgb 190 150 240)
                  (rgb 235 190 110) (rgb 120 200 200))
   ;; 同词着色：12 色粉彩（低饱和、明度接近），同词同色；取自 edit1 的 tokyo-night word 色板
   'word    (list (rgb 230 194 158) (rgb 216 204 152) (rgb 184 210 160) (rgb 162 212 172)
                  (rgb 152 214 202) (rgb 142 206 226) (rgb 150 196 236) (rgb 166 182 236)
                  (rgb 196 172 234) (rgb 206 172 226) (rgb 188 178 214) (rgb 178 198 214))
   'bracket (list (rgb 36 40 58) (rgb 28 47 49) (rgb 48 46 30) (rgb 30 49 40)
                  (rgb 42 34 58) (rgb 34 44 58) (rgb 38 48 34) (rgb 44 38 54))))

(define (palette-ref name) (hash-ref palettes name '()))

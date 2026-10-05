#lang racket

(require "theme.rkt"
         "slots.rkt")

;;; lab-rebuild/config/theme/dark.rkt —— 默认深色主题
;;;
;;; 结构：上面是**固定颜色表**（唯一改颜色的地方），下面是 `build-theme` 组装。
;;; 色值全是字面量，运行时不做任何计算。
;;;
;;; 可定义颜色的槽位见 slots.rkt（静态 face / 动态色板 kind / overlay）。
;;; 本主题覆盖：
;;;   face     line-number tree-* buf-* input state bar
;;;   palette  bracket（括号背景，按层）word（词前景）keyword（关键字前景）

(provide dark-theme)

;;; ================= 固定颜色表 =================

;; face 前景（#f = 不设）
(define dark-face-fg
  (hash 'line-number  '(90 96 110)
        'tree-dir     '(120 180 240)
        'tree-file    '(200 200 200)
        'tree-link    '(120 200 200)
        'tree-hidden  '(120 120 130)
        'tree-open    '(120 210 130)
        'input        '(20 20 20)
        'state        '(225 225 225)
        'bar          '(90 96 110)
        'buf-current  '(120 210 130)
        'buf-file     '(200 200 200)
        'buf-untitled '(170 170 170)
        'buf-view     '(140 160 190)))

;; face 背景（只有 input / state 需要）
(define dark-face-bg
  (hash 'input '(230 200 90)
        'state '(40 44 52)))

;; 未登记 face 的回落：浅灰字、不设底
(define dark-default (list '(205 205 205) #f))

;; overlay
(define dark-overlays
  (hash 'selection (list #f '(58 74 128))))

;; 动态色板（固定表）
(define dark-palettes
  (hash 'bracket (vector (list #f '(70 56 90))
                         (list #f '(44 74 66))
                         (list #f '(84 66 44))
                         (list #f '(52 62 92)))
        'word    (vector (list '(120 210 130) #f)
                         (list '(120 180 240) #f)
                         (list '(200 130 210) #f)
                         (list '(120 200 200) #f)
                         (list '(220 190 120) #f)
                         (list '(200 150 120) #f))
        'keyword (vector (list '(230 160 90) #f)
                         (list '(120 180 240) #f)
                         (list '(200 130 210) #f)
                         (list '(120 200 200) #f)
                         (list '(220 190 120) #f)
                         (list '(120 210 130) #f)
                         (list '(200 150 120) #f)
                         (list '(170 170 220) #f)
                         (list '(240 150 150) #f)
                         (list '(140 220 180) #f)
                         (list '(200 200 130) #f)
                         (list '(170 150 230) #f)
                         (list '(230 170 200) #f)
                         (list '(130 210 230) #f)
                         (list '(210 185 140) #f)
                         (list '(150 205 140) #f))))

;;; ================= 组装 =================

(define dark-theme
  (build-theme #:faces-fg dark-face-fg
               #:faces-bg dark-face-bg
               #:default  dark-default
               #:overlays dark-overlays
               #:palettes dark-palettes))

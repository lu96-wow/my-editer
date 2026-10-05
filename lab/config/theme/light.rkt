#lang racket

(require "theme.rkt"
         "slots.rkt")

;;; lab-rebuild/config/theme/light.rkt —— 浅色主题（face 名 / 色板 kind 同 dark.rkt）
;;;
;;; 结构同 dark.rkt：上面固定颜色表，下面 build-theme 组装。色值全是字面量。

(provide light-theme)

;;; ================= 固定颜色表 =================

(define light-face-fg
  (hash 'line-number  '(140 145 160)
        'tree-dir     '(30 90 180)
        'tree-file    '(40 40 40)
        'tree-link    '(0 120 120)
        'tree-hidden  '(150 150 150)
        'tree-open    '(20 130 40)
        'input        '(60 40 0)
        'state        '(35 35 35)
        'bar          '(170 175 190)
        'buf-current  '(20 130 40)
        'buf-file     '(40 40 40)
        'buf-untitled '(120 120 120)
        'buf-view     '(70 90 130)))

(define light-face-bg
  (hash 'input '(245 205 95)
        'state '(224 227 234)))

(define light-default (list '(20 20 20) #f))

(define light-overlays
  (hash 'selection (list #f '(180 205 240))))

(define light-palettes
  (hash 'bracket (vector (list #f '(232 220 245))
                         (list #f '(214 238 230))
                         (list #f '(248 232 205))
                         (list #f '(214 228 248)))
        'word    (vector (list '(20 130 40) #f)
                         (list '(30 90 180) #f)
                         (list '(150 60 150) #f)
                         (list '(0 120 120) #f)
                         (list '(160 110 0) #f)
                         (list '(170 80 40) #f))
        'keyword (vector (list '(150 70 0) #f)
                         (list '(30 90 180) #f)
                         (list '(150 60 150) #f)
                         (list '(0 120 120) #f)
                         (list '(160 110 0) #f)
                         (list '(20 130 40) #f)
                         (list '(170 80 40) #f)
                         (list '(80 80 170) #f)
                         (list '(180 30 30) #f)
                         (list '(0 120 70) #f)
                         (list '(120 120 0) #f)
                         (list '(100 50 170) #f)
                         (list '(170 40 110) #f)
                         (list '(0 110 150) #f)
                         (list '(140 100 30) #f)
                         (list '(60 130 60) #f))))

;;; ================= 组装 =================

(define light-theme
  (build-theme #:faces-fg light-face-fg
               #:faces-bg light-face-bg
               #:default  light-default
               #:overlays light-overlays
               #:palettes light-palettes))

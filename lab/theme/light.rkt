#lang racket

(require "theme.rkt")

;;; lab/theme/light.rkt —— 浅色主题（face 名同 dark.rkt）

(provide light-theme)

(define light-theme
  (theme
   (hash 'line-number  (list '(140 145 160) #f)
         'tree-dir     (list '(30 90 180) #f)
         'tree-file    (list '(40 40 40) #f)
         'tree-link    (list '(0 120 120) #f)
         'tree-hidden  (list '(150 150 150) #f)
         'tree-open    (list '(20 130 40) #f)
         'input        (list '(60 40 0) '(245 205 95))
         'state        (list '(35 35 35) '(224 227 234))
         'bar          (list '(170 175 190) #f)
         'buf-current  (list '(20 130 40) #f)
         'buf-file     (list '(40 40 40) #f)
         'buf-untitled (list '(120 120 120) #f)
         'buf-view     (list '(70 90 130) #f))
   (hash 'selection '(#f (180 205 240)))
   (list '(20 20 20) #f)
   ;; 括号背景色板，按嵌套深度取模；只设背景
   (vector (list #f '(232 220 245))
           (list #f '(214 238 230))
           (list #f '(248 232 205))
           (list #f '(214 228 248)))))

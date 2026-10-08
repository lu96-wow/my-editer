#lang racket

;;; lab-re-rebuild/config/theme.rkt —— 主题（纯数据 + 组装）。
;;;
;;; 可定义颜色的槽位集中在这里：静态 face / 动态色板 kind / overlay。
;;; 后端每帧读 (current-theme) 把 face 翻成 ANSI。

(require "../kernel/theme.rkt")

(provide current-theme dark-theme)

;;; ---------- 固定颜色表 ----------

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

(define dark-face-bg
  (hash 'input '(230 200 90)
        'state '(40 44 52)))

(define dark-default (list '(205 205 205) #f))

(define dark-overlays
  (hash 'selection (list #f '(58 74 128))))

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
                         (list '(140 220 180) #f))))

(define dark-theme
  (theme (for/hash ([s (in-list (hash-keys dark-face-fg))])
           (values s (list (hash-ref dark-face-fg s #f) (hash-ref dark-face-bg s #f))))
         dark-overlays dark-default dark-palettes))

(define current-theme (make-parameter dark-theme))

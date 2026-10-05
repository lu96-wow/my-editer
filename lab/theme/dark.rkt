#lang racket

(require "theme.rkt")

;;; lab/theme/dark.rkt —— 默认深色主题（原 tui.rkt 里的配色）
;;;
;;; face 名由各 view-model 定义：
;;;   ui/tree.rkt    tree-dir / tree-file / tree-link / tree-hidden / tree-open
;;;   ui/buffers.rkt buf-current / buf-file / buf-untitled / buf-view
;;;   ui/slot.rkt    input / state
;;;   app/render.rkt bar
;;;   core           line-number
;;; overlay 名：selection（cursor 由后端按反色处理，不走主题）。

(provide dark-theme)

(define dark-theme
  (theme
   (hash 'line-number  (list '(90 96 110) #f)
         'tree-dir     (list '(120 180 240) #f)
         'tree-file    (list '(200 200 200) #f)
         'tree-link    (list '(120 200 200) #f)
         'tree-hidden  (list '(120 120 130) #f)
         'tree-open    (list '(120 210 130) #f)
         'input        (list '(20 20 20) '(230 200 90))
         'state        (list '(225 225 225) '(40 44 52))
         'bar          (list '(90 96 110) #f)
         'buf-current  (list '(120 210 130) #f)
         'buf-file     (list '(200 200 200) #f)
         'buf-untitled (list '(170 170 170) #f)
         'buf-view     (list '(140 160 190) #f))
   (hash 'selection '(#f (58 74 128)))
   (list '(205 205 205) #f)))

#lang racket

(require "base/screen.rkt" "base/viewport.rkt"
         "project.rkt" "overlay.rkt"
         "../text/document.rkt")

;;; render.rkt —— 组合层：project（文本通道）⊕ overlay（视图通道）→ screen
;;;
;;;   vrows = viewport-vrows          ; 唯一中间量，算一次
;;;   rows  = project  bd vp vrows    ; 文本 + 行号栏
;;;   overlay = overlay-cursors/regions t vp vrows sels
;;;   screen  = rows ⊕ overlay
;;;
;;; clip / wrap 的差别只在 viewport-vrows 产出的 vrow 序列；本层一视同仁。
;;; selections 省略 / #f → 只画文本（无光标 / 选区）。

(provide
 ;; project ⊕ overlay → screen
 render)

(define (render bd vp [sels #f])
  (define t (document-text bd))
  (define vrows (viewport-vrows t vp))
  (define-values (rows gutter) (project bd vp vrows))
  (screen (viewport-width vp) (viewport-height vp)
          rows
          (if sels (overlay-cursors t vp vrows sels) '())
          (if sels (overlay-regions t vp vrows sels gutter) '())))

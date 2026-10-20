#lang racket

;;; edit-tui-rebuild/render/core.rkt —— core piece -> tui 序列（纯）
;;;
;;; 只做：
;;;   · piece -> bytes
;;;   · face / overlay 解释成 tui 样式
;;;   · 清屏
;;;
;;; 何时渲染、是否增量、何时输出由上层决定。

(require tui
         "../core/face/api.rkt"
         "../../core/editor.rkt")

(provide render-pieces
         render-clear)

(define (fragment . parts)
  (apply bytes-append (filter values parts)))

(define (render-piece p)
  (fragment
   (format-cursor-move (add1 (piece-row p)) (add1 (piece-column p)))
   (attr-fragment (piece-attr p))
   (format-content (piece-text p))
   format-reset))

(define (render-pieces ps)
  (apply fragment (map render-piece ps)))

(define (attr-fragment attr)
  (cond
    [(pair? attr) (fragment (face-fragment (cdr attr)) (style-fragment (car attr)))]
    [else (face-fragment attr)]))

(define (face-fragment f)
  (cond
    [(not f) #f]
    [(symbol? f) (style-fragment f)]
    [else
     (fragment
      (style-fragment (face-fg f))
      (style-fragment (face-bg f))
      (apply fragment (map style-fragment (face-attrs f))))]))

(define (style-fragment name)
  (and name (style->bytes name)))

(define (render-clear)
  (fragment format-screen-clear))

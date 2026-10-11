#lang racket

;;; edit3/render.rkt —— geometry → core rectangle → piece
;;;
;;; 把求解出来的 placements（wid/vid/rect/z）交给 core 合成；focus 的 vid = active（透出光标）。

(provide render)

(require "state.rkt" "border.rkt" "adapter.rkt")

(define (focus-vid st placements)
  (for/first ([p (in-list placements)]
              #:when (eqv? (state-focus st) (placement-wid p)))
    (placement-vid p)))

(define (render st g old)
  (define placements (geometry-placements g))
  (render-layout (state-ed st) (content-placements st placements) (focus-vid st placements)
                 (geometry-w g) (geometry-h g) old (border-runs st g)))

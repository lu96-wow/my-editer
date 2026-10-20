#lang racket

;;; edit-tui-rebuild/runtime/render.rkt —— state + cache -> bytes
;;;
;;; view resolver：State 里存 view-id，engine 里存 core view。

(require "../skeleton/api.rkt"
         "../app/state.rkt"
         "../render/layout.rkt")

(provide render-frame)

;; → (values cache' bytes)
(define (render-frame state engine cache)
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (define focus (layout-focus layout))
  (render-layout layout area
                 #:focus-panel focus
                 #:cache cache
                 #:view-object (λ (vid) (engine-view-object engine vid))))

#lang racket

;;; edit-tui-rebuild/boot/frame.rkt —— state + cache -> bytes（每帧渲染入口）
;;;
;;; view resolver：State 里存 view-id，engine 里存 core view。

(require "../core/skeleton.rkt"
         "../app/state.rkt"
         "../render/layout.rkt")

(provide render-frame)

;; → (values cache' bytes)
(define (render-frame state engine cache
                      #:solution [solution #f]
                      #:panels [panels #f]
                      #:overlays [overlays (list)])
  (define layout (app-state-layout state))
  (define area (app-state-area state))
  (define focus (layout-focus layout))
  (render-layout layout area
                 #:focus-panel focus
                 #:cache cache
                 #:view-object (λ (vid) (engine-view-object engine vid))
                 #:solution solution
                 #:panels panels
                 #:overlays overlays))

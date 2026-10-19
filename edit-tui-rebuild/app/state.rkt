#lang racket

;;; edit-tui-rebuild/app/state.rkt —— 根 State（纯）

(require "../resource/api.rkt")

(provide (struct-out app-state)
         make-app-state)

(struct app-state
  (layout
   resources
   focus-resource
   overlays        ; (listof command-table)，顶层在前
   pending         ; (listof key-token)
   area            ; rect
   quit?
   message)
  #:transparent)

(define (make-app-state
         #:layout [layout #f]
         #:resources [resources resource-store-empty]
         #:focus-resource [focus-resource #f]
         #:overlays [overlays '()]
         #:pending [pending '()]
         #:area [area #f]
         #:quit? [quit? #f]
         #:message [message ""])
  (app-state layout resources focus-resource overlays pending area quit? message))

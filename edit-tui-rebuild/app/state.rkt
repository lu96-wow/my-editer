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
   next-panel-id
   drag            ; layout drag | #f
   placement       ; view-id | #f
   store           ; 面板 UI 状态：'filetree -> filetree ...
   root            ; 工作区根目录
   panel-stacks    ; panel-id -> command-table-stack
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
         #:next-panel-id [next-panel-id 100]
         #:drag [drag #f]
         #:placement [placement #f]
         #:store [store (hash)]
         #:root [root ""]
         #:panel-stacks [panel-stacks (hash)]
         #:quit? [quit? #f]
         #:message [message ""])
  (app-state layout resources focus-resource overlays pending area
             next-panel-id drag placement store root panel-stacks
             quit? message))

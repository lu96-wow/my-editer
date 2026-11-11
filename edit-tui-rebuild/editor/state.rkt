#lang racket

;;; edit-tui-rebuild/editor/state.rkt —— 纯 editor state
;;;
;;; State 不存 engine 句柄、不存 IO 结果、不存 lambda。
;;; 插件状态按 owner（plugin id）分命名空间存在 plugin-states 里；
;;; 每个插件只通过自己的 accessor 读写自己的状态。
;;;
;;; area / pending / flash 是宿主也要用的公共状态。

(require "../core/api.rkt")

(provide (struct-out editor-state)
         make-editor-state
         editor-state-plugin-state
         editor-state-set-plugin-state
         editor-state-with-flash
         editor-state-clear-flash
         editor-state-with-pending
         editor-state-clear-pending)

(struct editor-state
  (plugin-states   ; hash: plugin-id -> opaque pure value
   pending         ; (listof key-token)
   quit?
   flash           ; string，一次性；下一次 step 入口清空
   area            ; rect | #f
   layout          ; layout | #f（core/layout 的纯值）
   drag            ; layout seam drag | #f
   next-view-id    ; 新 split 使用的 view id
   next-panel-id)  ; 新 split 使用的 panel id
  #:transparent)

(define (make-editor-state
         #:plugin-states [plugin-states (hash)]
         #:pending [pending '()]
         #:quit? [quit? #f]
         #:flash [flash ""]
         #:area [area #f]
         #:layout [layout #f]
         #:drag [drag #f]
         #:next-view-id [next-view-id 10]
         #:next-panel-id [next-panel-id 100])
  (editor-state plugin-states pending quit? flash area
                layout drag next-view-id next-panel-id))

(define (editor-state-plugin-state state owner)
  (hash-ref (editor-state-plugin-states state) owner #f))

(define (editor-state-set-plugin-state state owner value)
  (struct-copy editor-state state
               [plugin-states
                (hash-set (editor-state-plugin-states state) owner value)]))

(define (editor-state-with-flash state text)
  (struct-copy editor-state state [flash text]))

(define (editor-state-clear-flash state)
  (if (string=? (editor-state-flash state) "")
      state
      (struct-copy editor-state state [flash ""])))

(define (editor-state-with-pending state pending)
  (struct-copy editor-state state [pending pending]))

(define (editor-state-clear-pending state)
  (if (null? (editor-state-pending state))
      state
      (struct-copy editor-state state [pending '()])))

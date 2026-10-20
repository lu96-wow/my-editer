#lang racket

;;; edit-tui-rebuild/app/state.rkt —— 根 State（纯） + 焦点相关的状态迁移
;;;
;;; State 只存 id / 纯值，不碰 engine、不碰 IO。
;;;
;;; 焦点有两层：
;;;   layout.focus   : 焦点 panel-id（布局层，layout/api）
;;;   focus-resource : 焦点 panel 的活动 view 所属 resource（派生量，缓存在 Root）
;;;
;;; 「改焦点」必须走 app-state-set-focus-panel：它会同步刷新 focus-resource。
;;; 直接改 layout 会让 focus-resource 过期，所以这里把两者绑在一个操作里。

(require "../skeleton.rkt"
         "keymap.rkt")

(provide (struct-out app-state)
         make-app-state

         ;; 查询
         app-state-panel
         app-state-focus-panel-id
         app-state-focus-panel-resource
         app-state-focus-view-id

         ;; 纯迁移
         app-state-with-message
         app-state-set-focus-panel
         app-state-refresh-focus-resource)

(struct app-state
  (layout
   layout-config   ; 具体 kind 规则；宿主选择（默认 empty = 通用 rule）
   keymap          ; 键位集合；宿主选择（默认 empty = 无绑定）
   resources
   focus-resource
   overlays        ; command-table-stack，顶层在前
   pending         ; (listof key-token)
   area            ; rect
   next-panel-id
   drag            ; layout drag | #f
   placement       ; view-id | #f
   store           ; 面板 UI 状态：'filetree -> filetree、'input -> input-state ...
   root            ; 工作区根目录
   panel-stacks    ; panel-id -> command-table-stack
   quit?
   message)
  #:transparent)

(define (make-app-state
         #:layout [layout #f]
         #:layout-config [layout-config empty-layout-config]
         #:keymap [keymap empty-keymap]
         #:resources [resources resource-store-empty]
         #:focus-resource [focus-resource #f]
         #:overlays [overlays command-table-stack-empty]
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
  (app-state layout layout-config keymap resources focus-resource overlays pending area
             next-panel-id drag placement store root panel-stacks
             quit? message))

;;; ════════════════ 查询 ════════════════

(define (app-state-panel state id)
  (define layout (app-state-layout state))
  (and layout id (layout-panel layout id)))

(define (app-state-focus-panel-id state)
  (define layout (app-state-layout state))
  (and layout (layout-focus layout)))

(define (app-state-focus-panel-resource state)
  (app-state-panel state (app-state-focus-panel-id state)))

(define (app-state-focus-view-id state)
  (define p (app-state-focus-panel-resource state))
  (and p (panel-view p)))

;; 焦点 view 所属的 resource（内部用）
(define (focus-resource-of-view state vid)
  (and vid (resource-of-view (app-state-resources state) vid)))

;;; ════════════════ 纯迁移 ════════════════

(define (app-state-with-message state text)
  (struct-copy app-state state [message text]))

;; 焦点 panel 没变，只按当前 view 重算 focus-resource（换 view / 隐藏恢复后用）。
(define (app-state-refresh-focus-resource state)
  (struct-copy app-state state
               [focus-resource
                (focus-resource-of-view state (app-state-focus-view-id state))]))

;; 改焦点 panel：layout.focus 与 focus-resource 一起更新。
(define (app-state-set-focus-panel state pid)
  (define layout* (layout-set-focus (app-state-layout state) pid))
  (app-state-refresh-focus-resource
   (struct-copy app-state state [layout layout*])))

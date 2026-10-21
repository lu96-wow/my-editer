#lang racket

;;; edit-tui-rebuild/app/state.rkt —— 根 State（纯） + 焦点相关的状态迁移
;;;
;;; State 只存 id / 纯值，不碰 engine、不碰 IO。
;;;
;;; 焦点有两层：
;;;   layout.focus    : 焦点 panel-id（布局层，layout/api）
;;;   focus-resource  : 焦点 panel 的活动 view 所属 resource（派生量，不存 State）
;;;
;;; focus-resource 每次从 layout / panel.active / resources 现算，
;;; 因此不存在「直接改 layout 后缓存过期」的问题。

(require "../core/skeleton.rkt"
         "keymap.rkt")

(provide (struct-out app-state)
         make-app-state

         ;; 查询
         app-state-panel
         app-state-focus-panel-id
         app-state-focus-panel-resource
         app-state-focus-view-id
         app-state-focus-resource

         ;; 纯迁移
         app-state-with-flash
         app-state-set-focus-panel)

(struct app-state
  (layout
   layout-config   ; 具体 kind 规则；宿主选择（默认 empty = 通用 rule）
   keymap          ; 键位集合；宿主选择（默认 empty = 无绑定）
   resources
   overlays        ; command-table-stack，顶层在前
   pending         ; (listof key-token)
   area            ; rect
   next-panel-id
   drag            ; layout drag | #f
   placement       ; view-id | #f
   store           ; 面板 UI 状态：'filetree -> filetree、'input -> input-state ...
   panel-stacks    ; panel-id -> command-table-stack
   quit?
   flash)   ; 一次性状态栏文本；下一次 step 入口清空
  #:transparent)

(define (make-app-state
         #:layout [layout #f]
         #:layout-config [layout-config empty-layout-config]
         #:keymap [keymap empty-keymap]
         #:resources [resources resource-store-empty]
         #:overlays [overlays command-table-stack-empty]
         #:pending [pending '()]
         #:area [area #f]
         #:next-panel-id [next-panel-id 100]
         #:drag [drag #f]
         #:placement [placement #f]
         #:store [store (hash)]
         #:panel-stacks [panel-stacks (hash)]
         #:quit? [quit? #f]
         #:flash [flash ""])
  (app-state layout layout-config keymap resources overlays pending area
             next-panel-id drag placement store panel-stacks
             quit? flash))

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

;; 焦点 view 所属的 resource。派生查询，不缓存。
(define (app-state-focus-resource state)
  (define vid (app-state-focus-view-id state))
  (and vid (resource-of-view (app-state-resources state) vid)))

;;; ════════════════ 纯迁移 ════════════════

;; 一次性状态栏文本：只存在到下一次 step。
;; 需要跨事件保留的信息不要放这里，放各自的状态字段。
(define (app-state-with-flash state text)
  (struct-copy app-state state [flash text]))

;; 改焦点 panel。focus-resource 是派生量，不需要同步。
(define (app-state-set-focus-panel state pid)
  (struct-copy app-state state
               [layout (layout-set-focus (app-state-layout state) pid)]))

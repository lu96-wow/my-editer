#lang racket

;;; edit-tui-rebuild/app/state.rkt —— 根 State（纯） + 焦点相关的状态迁移
;;;
;;; State 只存 id / 纯值，不碰 engine、不碰 IO。
;;;
;;; 焦点 / 键盘归属：
;;;   layout.focus    : 焦点 panel-id（布局层，layout/api）
;;;   focus-resource  : 焦点 panel 的活动 view 所属 resource（派生量，不存 State）
;;;   key-owner       : 当前键盘模式标签（'layout | 'completion-menu | ...）
;;;   key-owner-stack : 该模式的顶层命令表；#f = 回落到 layout stack
;;;
;;; focus-resource 每次从 layout / panel.active / resources 现算，
;;; 因此不存在「直接改 layout 后缓存过期」的问题。

(require "../core/skeleton.rkt"
         "keymap.rkt")

(provide (struct-out app-state)
         make-app-state

         ;; 鼠标拖选：正在拖的 panel / view（anchor 由 view 的 selection 持有）
         (struct-out select-drag)

         ;; 文档变更（engine -> boot/analysis 的纯数据通道）
         (struct-out doc-change)
         app-state-note-doc-change
         app-state-clear-doc-changes
         app-state-take-doc-changes

         ;; 键盘 owner
         app-state-set-key-owner
         app-state-clear-key-owner

         ;; 查询
         app-state-panel
         app-state-focus-panel-id
         app-state-focus-panel-resource
         app-state-focus-view-id
         app-state-focus-resource

         ;; 纯迁移
         app-state-with-flash
         app-state-set-focus-panel)

;; 鼠标拖动选区（纯值）。
;;   panel-id : 按下时的 panel（拖动期间选择始终留在这个 panel）
;;   view-id  : 该 panel 的 active view
;; anchor 不在这里：按下时 point action 已经把 caret 写进 view，
;; 后续 extend 只移动 head，anchor 自然留在 view 的 selection 里。
(struct select-drag (panel-id view-id) #:transparent)

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
   select-drag     ; select-drag | #f
   placement       ; view-id | #f
   store           ; 面板 UI 状态：'filetree -> filetree、'input -> input-state ...
   panel-stacks    ; panel-id -> command-table-stack
   quit?
   flash           ; 一次性状态栏文本；下一次 step 入口清空
   pending-doc-changes ; (listof doc-change)，按发生顺序
   key-owner       ; symbol：'layout | 'completion-menu | ...
   key-owner-stack) ; command-table-stack | #f：owner 的顶层键盘表
  #:transparent)

;; 一次提交（一次 buffer-edit! / replace-range! / undo/redo）产生的 change。
;; changes 是 core 的纯值列表；version 是提交完成后的 engine 文档版本。
(struct doc-change (doc-id version changes) #:transparent)

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
         #:select-drag [select-drag #f]
         #:placement [placement #f]
         #:store [store (hash)]
         #:panel-stacks [panel-stacks (hash)]
         #:quit? [quit? #f]
         #:flash [flash ""]
         #:pending-doc-changes [pending-doc-changes '()]
         #:key-owner [key-owner 'layout]
         #:key-owner-stack [key-owner-stack #f])
  (app-state layout layout-config keymap resources overlays pending area
             next-panel-id drag select-drag placement store panel-stacks
             quit? flash pending-doc-changes key-owner key-owner-stack))

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

;;; ════════════════ 文档变更队列 ════════════════

;; changes = #f | '() | (listof change)；只有非空列表才入队。
(define (app-state-note-doc-change state did version changes)
  (cond
    [(not (pair? changes)) state]
    [else
     (struct-copy app-state state
                  [pending-doc-changes
                   (append (app-state-pending-doc-changes state)
                           (list (doc-change did version changes)))])]))

(define (app-state-clear-doc-changes state)
  (if (null? (app-state-pending-doc-changes state))
      state
      (struct-copy app-state state [pending-doc-changes '()])))

(define (app-state-take-doc-changes state)
  (values (app-state-pending-doc-changes state)
          (app-state-clear-doc-changes state)))

;;; ════════════════ 键盘 owner ════════════════

(define (app-state-set-key-owner state owner stack)
  (unless (symbol? owner)
    (raise-argument-error 'app-state-set-key-owner "symbol?" owner))
  (unless (or (not stack) (command-table-stack? stack))
    (raise-argument-error 'app-state-set-key-owner
                          "(or/c #f command-table-stack?)" stack))
  (struct-copy app-state state [key-owner owner] [key-owner-stack stack]))

(define (app-state-clear-key-owner state)
  (if (and (eq? (app-state-key-owner state) 'layout)
           (not (app-state-key-owner-stack state)))
      state
      (struct-copy app-state state [key-owner 'layout] [key-owner-stack #f])))

;;; ════════════════ 纯迁移 ════════════════

;; 一次性状态栏文本：只存在到下一次 step。
;; 需要跨事件保留的信息不要放这里，放各自的状态字段。
(define (app-state-with-flash state text)
  (struct-copy app-state state [flash text]))

;; 改焦点 panel。focus-resource 是派生量，不需要同步。
(define (app-state-set-focus-panel state pid)
  (struct-copy app-state state
               [layout (layout-set-focus (app-state-layout state) pid)]))

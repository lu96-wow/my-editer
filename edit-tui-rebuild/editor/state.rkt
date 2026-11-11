#lang racket

;;; edit-tui-rebuild/editor/state.rkt —— editor core + session 分层
;;;
;;; editor-core    文档 / 布局 / 插件状态：editor 操作面真正拥有的状态。
;;; editor-session 输入栏 / placement / 鼠标 / job / quit / flash：host 会话状态。
;;;
;;; 顶层 editor-state 仍是纯值，也仍兼容旧的 accessor；但字段已经按 owner
;;; 分开。等 host app-state 接好后，editor-session 可以整体移出 editor。
;;;
;;; State 不存 engine 句柄、不存 IO 结果、不存 lambda。

(require "../core/api.rkt"
         "../core/job/api.rkt"
         "../core/layout/config.rkt"
         "resource.rkt")

(provide (struct-out editor-state)
         (struct-out select-drag)
         (struct-out editor-core)
         (struct-out editor-session)
         make-editor-state

         ;; core accessor / update
         editor-state-plugin-states
         editor-state-resources
         editor-state-layout
         editor-state-layout-config
         editor-state-area
         editor-state-next-view-id
         editor-state-next-panel-id
         editor-state-with-plugin-states
         editor-state-with-resources
         editor-state-with-layout
         editor-state-with-layout-config
         editor-state-with-area
         editor-state-with-next-view-id
         editor-state-with-next-panel-id

         ;; session accessor / update
         editor-state-pending
         editor-state-quit?
         editor-state-flash
         editor-state-drag
         editor-state-select-drag
         editor-state-placement
         editor-state-input
         editor-state-jobs
         editor-state-async?
         editor-state-with-pending
         editor-state-clear-pending
         editor-state-with-quit
         editor-state-with-flash
         editor-state-clear-flash
         editor-state-with-drag
         editor-state-with-select-drag
         editor-state-with-placement
         editor-state-with-input
         editor-state-with-jobs
         editor-state-with-async

         editor-state-plugin-state
         editor-state-set-plugin-state
         editor-state-resource-for-view
         editor-state-resource-for-doc
         editor-state-doc-mode
         editor-state-opened-paths)

;; 鼠标文本拖选：选择留在按下的 panel / view 里。
(struct select-drag (panel-id view-id) #:transparent)

;; editor 核心：只由 editor 操作面解释。
(struct editor-core
  (plugin-states   ; hash: plugin-id -> opaque pure value
   resources       ; resources：已打开文档
   layout          ; layout | #f（core/layout 的纯值）
   layout-config   ; layout-config：具体 kind 规则（宿主选择）
   area            ; rect | #f
   next-view-id    ; 新 split 使用的 view id
   next-panel-id)  ; 新 split 使用的 panel id
  #:transparent)

;; host 会话：输入 / placement / 鼠标 / job / quit / flash。
(struct editor-session
  (pending         ; (listof key-token)
   quit?
   flash           ; string，一次性；下一次 step 入口清空
   drag            ; layout seam drag | #f
   select-drag     ; select-drag | #f：鼠标文本拖选
   placement       ; view-id | #f：等待放入 editor panel
   input           ; input-state | #f：单行输入栏
   jobs            ; job-ledger
   async?)         ; bool：sync 阶段是否走异步 job
  #:transparent)

(struct editor-state (core session) #:transparent)

(define (make-editor-state
         #:plugin-states [plugin-states (hash)]
         #:pending [pending '()]
         #:quit? [quit? #f]
         #:flash [flash ""]
         #:area [area #f]
         #:layout-config [layout-config empty-layout-config]
         #:layout [layout #f]
         #:drag [drag #f]
         #:next-view-id [next-view-id 10]
         #:next-panel-id [next-panel-id 100]
         #:resources [resources empty-resources]
         #:placement [placement #f]
         #:input [input #f]
         #:select-drag [select-drag #f]
         #:jobs [jobs empty-job-ledger]
         #:async? [async? #f])
  (editor-state
   (editor-core plugin-states resources layout layout-config area
                next-view-id next-panel-id)
   (editor-session pending quit? flash drag select-drag placement
                   input jobs async?)))

;;; ════════════════ core accessor / update ════════════════

(define (editor-state-plugin-states state)
  (editor-core-plugin-states (editor-state-core state)))
(define (editor-state-resources state)
  (editor-core-resources (editor-state-core state)))
(define (editor-state-layout state)
  (editor-core-layout (editor-state-core state)))
(define (editor-state-layout-config state)
  (editor-core-layout-config (editor-state-core state)))
(define (editor-state-area state)
  (editor-core-area (editor-state-core state)))
(define (editor-state-next-view-id state)
  (editor-core-next-view-id (editor-state-core state)))
(define (editor-state-next-panel-id state)
  (editor-core-next-panel-id (editor-state-core state)))

(define (editor-state-with-core state core)
  (struct-copy editor-state state [core core]))

(define (editor-state-with-plugin-states state plugin-states)
  (editor-state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [plugin-states plugin-states])))
(define (editor-state-with-resources state resources)
  (editor-state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [resources resources])))
(define (editor-state-with-layout state layout)
  (editor-state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [layout layout])))
(define (editor-state-with-layout-config state layout-config)
  (editor-state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [layout-config layout-config])))
(define (editor-state-with-area state area)
  (editor-state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [area area])))
(define (editor-state-with-next-view-id state next-view-id)
  (editor-state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [next-view-id next-view-id])))
(define (editor-state-with-next-panel-id state next-panel-id)
  (editor-state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [next-panel-id next-panel-id])))

;;; ════════════════ session accessor / update ════════════════

(define (editor-state-pending state)
  (editor-session-pending (editor-state-session state)))
(define (editor-state-quit? state)
  (editor-session-quit? (editor-state-session state)))
(define (editor-state-flash state)
  (editor-session-flash (editor-state-session state)))
(define (editor-state-drag state)
  (editor-session-drag (editor-state-session state)))
(define (editor-state-select-drag state)
  (editor-session-select-drag (editor-state-session state)))
(define (editor-state-placement state)
  (editor-session-placement (editor-state-session state)))
(define (editor-state-input state)
  (editor-session-input (editor-state-session state)))
(define (editor-state-jobs state)
  (editor-session-jobs (editor-state-session state)))
(define (editor-state-async? state)
  (editor-session-async? (editor-state-session state)))

(define (editor-state-with-session state session)
  (struct-copy editor-state state [session session]))

(define (editor-state-with-pending state pending)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [pending pending])))
(define (editor-state-clear-pending state)
  (if (null? (editor-state-pending state))
      state
      (editor-state-with-pending state '())))
(define (editor-state-with-quit state quit?)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [quit? quit?])))
(define (editor-state-with-flash state text)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [flash text])))
(define (editor-state-clear-flash state)
  (if (string=? (editor-state-flash state) "")
      state
      (editor-state-with-flash state "")))
(define (editor-state-with-drag state drag)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [drag drag])))
(define (editor-state-with-select-drag state select-drag)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [select-drag select-drag])))
(define (editor-state-with-placement state placement)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [placement placement])))
(define (editor-state-with-input state input)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [input input])))
(define (editor-state-with-jobs state jobs)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [jobs jobs])))
(define (editor-state-with-async state async?)
  (editor-state-with-session
   state
   (struct-copy editor-session (editor-state-session state)
                [async? async?])))

;;; ════════════════ plugin-state ════════════════

(define (editor-state-plugin-state state owner)
  (hash-ref (editor-state-plugin-states state) owner #f))

(define (editor-state-set-plugin-state state owner value)
  (editor-state-with-plugin-states
   state
   (hash-set (editor-state-plugin-states state) owner value)))

;;; ════════════════ resource 查询 ════════════════

(define (editor-state-resource-for-view state vid)
  (and vid (resources-find-view (editor-state-resources state) vid)))

(define (editor-state-resource-for-doc state did)
  (and did (resources-find-doc (editor-state-resources state) did)))

(define (editor-state-doc-mode state did)
  (define r (editor-state-resource-for-doc state did))
  (and r (resource-mode r)))

(define (editor-state-opened-paths state)
  (resources-opened-paths (editor-state-resources state)))

#lang racket

;;; edit-tui-rebuild/editor/state.rkt —— editor core + host app state
;;;
;;; editor-core    文档 / 布局 / 插件状态：editor 操作面真正拥有的状态。
;;; editor-session 输入栏 / placement / 鼠标 / job / quit / flash：host 会话状态。
;;; app-state      host 顶层状态：editor-core + editor-session。
;;;
;;; accessor / update helper 同时接受 app-state 和 editor-core：
;;;   · 读 core 字段：从 app-state 取 editor，或直接读 core。
;;;   · 写 core 字段：app-state 保留 session，core 直接返回新 core。
;;;   · 写 session 字段：必须有 app-state；core 不能承载 host 会话。
;;;
;;; 这样 editor 内部仍只依赖 core；host / feature / command 可以传 app-state，
;;; 操作面更新 core 时不会碰 session。

(require "../core/api.rkt"
         "../core/job/api.rkt"
         "../core/layout/config.rkt"
         "resource.rkt")

(provide (struct-out app-state)
         (struct-out editor-core)
         (struct-out editor-session)
         (struct-out select-drag)
         make-app-state
         editor-state-core
         editor-state-session

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

;; host 顶层状态：editor 只操作 editor，session 只由 host/base feature 改。
(struct app-state (editor session) #:transparent)

(define (make-app-state
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
  (app-state
   (editor-core plugin-states resources layout layout-config area
                next-view-id next-panel-id)
   (editor-session pending quit? flash drag select-drag placement
                   input jobs async?)))

;;; ════════════════ state dispatch ════════════════

(define (editor-state-core state)
  (cond
    [(app-state? state) (app-state-editor state)]
    [(editor-core? state) state]
    [else
     (raise-argument-error 'editor-state-core "app-state? or editor-core?" state)]))

(define (editor-state-session state)
  (cond
    [(app-state? state) (app-state-session state)]
    [(editor-core? state) #f]
    [else
     (raise-argument-error 'editor-state-session "app-state? or editor-core?" state)]))

(define empty-session
  (editor-session '() #f "" #f #f #f #f empty-job-ledger #f))

(define (session-of state)
  (or (editor-state-session state) empty-session))

(define (state-with-core state core)
  (cond
    [(app-state? state) (struct-copy app-state state [editor core])]
    [else core]))

(define (state-with-session state session)
  (cond
    [(app-state? state) (struct-copy app-state state [session session])]
    [else
     (error 'editor-state-with-session
            "session 字段只存在于 app-state，收到：~a" state)]))

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

(define (editor-state-with-plugin-states state plugin-states)
  (state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [plugin-states plugin-states])))
(define (editor-state-with-resources state resources)
  (state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [resources resources])))
(define (editor-state-with-layout state layout)
  (state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [layout layout])))
(define (editor-state-with-layout-config state layout-config)
  (state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [layout-config layout-config])))
(define (editor-state-with-area state area)
  (state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [area area])))
(define (editor-state-with-next-view-id state next-view-id)
  (state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [next-view-id next-view-id])))
(define (editor-state-with-next-panel-id state next-panel-id)
  (state-with-core
   state
   (struct-copy editor-core (editor-state-core state)
                [next-panel-id next-panel-id])))

;;; ════════════════ session accessor / update ════════════════

(define (editor-state-pending state)
  (editor-session-pending (session-of state)))
(define (editor-state-quit? state)
  (editor-session-quit? (session-of state)))
(define (editor-state-flash state)
  (editor-session-flash (session-of state)))
(define (editor-state-drag state)
  (editor-session-drag (session-of state)))
(define (editor-state-select-drag state)
  (editor-session-select-drag (session-of state)))
(define (editor-state-placement state)
  (editor-session-placement (session-of state)))
(define (editor-state-input state)
  (editor-session-input (session-of state)))
(define (editor-state-jobs state)
  (editor-session-jobs (session-of state)))
(define (editor-state-async? state)
  (editor-session-async? (session-of state)))

(define (update-session state f)
  (state-with-session state (f (session-of state))))

(define (editor-state-with-pending state pending)
  (update-session state (λ (s) (struct-copy editor-session s [pending pending]))))
(define (editor-state-clear-pending state)
  (if (null? (editor-state-pending state))
      state
      (editor-state-with-pending state '())))
(define (editor-state-with-quit state quit?)
  (update-session state (λ (s) (struct-copy editor-session s [quit? quit?]))))
(define (editor-state-with-flash state text)
  (update-session state (λ (s) (struct-copy editor-session s [flash text]))))
(define (editor-state-clear-flash state)
  (if (string=? (editor-state-flash state) "")
      state
      (editor-state-with-flash state "")))
(define (editor-state-with-drag state drag)
  (update-session state (λ (s) (struct-copy editor-session s [drag drag]))))
(define (editor-state-with-select-drag state select-drag)
  (update-session state (λ (s) (struct-copy editor-session s [select-drag select-drag]))))
(define (editor-state-with-placement state placement)
  (update-session state (λ (s) (struct-copy editor-session s [placement placement]))))
(define (editor-state-with-input state input)
  (update-session state (λ (s) (struct-copy editor-session s [input input]))))
(define (editor-state-with-jobs state jobs)
  (update-session state (λ (s) (struct-copy editor-session s [jobs jobs]))))
(define (editor-state-with-async state async?)
  (update-session state (λ (s) (struct-copy editor-session s [async? async?]))))

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

#lang racket

;;; edit-tui/editor/state.rkt —— editor core + host app state
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
         state-core
         state-session

         ;; core accessor / update
         state-plugin-states
         state-workspace-root
         state-resources
         state-layout
         state-layout-config
         state-view-scopes
         state-area
         state-next-view-id
         state-next-panel-id
         state-with-plugin-states
         state-with-workspace-root
         state-with-resources
         state-with-layout
         state-with-layout-config
         state-with-view-scopes
         state-with-area
         state-with-next-view-id
         state-with-next-panel-id

         ;; session accessor / update
         state-pending
         state-pending-scope
         state-quit?
         state-flash
         state-drag
         state-select-drag
         state-find
         state-placement
         state-input
         state-input-seed
         state-jobs
         state-errors
         state-async?
         state-with-pending
         state-with-pending-scope
         state-clear-pending
         state-with-quit
         state-with-flash
         state-clear-flash
         state-with-drag
         state-with-select-drag
         state-with-find
         state-with-placement
         state-with-input
         state-with-jobs
         state-with-errors
         state-with-async

         state-plugin-state
         state-set-plugin-state
         state-resource-for-view
         state-resource-for-doc
         state-doc-mode
         state-opened-paths)

;; 鼠标文本拖选：选择留在按下的 panel / view 里。
(struct select-drag (panel-id view-id) #:transparent)

;; editor 核心：只由 editor 操作面解释。
(struct editor-core
  (plugin-states   ; hash: plugin-id -> opaque pure value
   workspace-root  ; normalized absolute path | #f：resources 相对路径的基准
   resources       ; resources：已打开文档
   layout          ; layout | #f（core/layout 的纯值）
   layout-config   ; layout-config：具体 kind 规则（宿主选择）
   view-scopes     ; hash view-id/panel-id -> command scope
   area            ; rect | #f
   next-view-id    ; 新 split 使用的 view id
   next-panel-id)  ; 新 split 使用的 panel id
  #:transparent)

;; host 会话按正交轴分组：
;;   modal   : #f | 'input | modal-placement
;;   pointer : #f | pointer-drag | pointer-select
;; input 是 input-state 的持久 seed：modal 退出后仍保留，下一次 open 直接复用。
;; 每个轴内部互斥；不同轴可以同时存在（例如 find + select-drag）。
(struct modal-placement (value) #:transparent)
(struct pointer-drag (value) #:transparent)
(struct pointer-select (value) #:transparent)

;; host 会话：输入 / placement / 鼠标 / job / quit / flash。
(struct editor-session
  (pending         ; (listof key-token)
   pending-scope   ; pending 对应的 scope key
   quit?
   flash           ; string，一次性；下一次 step 入口清空
   modal           ; #f | 'input | modal-placement
   input           ; input-state | #f：输入栏 seed（不随 modal 退出而丢弃）
   pointer         ; #f | pointer-drag | pointer-select
   find            ; find-state | #f：当前查找会话
   jobs            ; job-ledger
   errors          ; (listof editor-error)，最新在前
   async?)         ; bool：sync 阶段是否走异步 job
  #:transparent)

;; host 顶层状态：editor 只操作 editor，session 只由 host/base feature 改。
(struct app-state (editor session) #:transparent)

(define (make-app-state
         #:plugin-states [plugin-states (hash)]
         #:workspace-root [workspace-root #f]
         #:pending [pending '()]
         #:pending-scope [pending-scope #f]
         #:quit? [quit? #f]
         #:flash [flash ""]
         #:area [area #f]
         #:layout-config [layout-config empty-layout-config]
         #:layout [layout #f]
         #:view-scopes [view-scopes (hash)]
         #:drag [drag #f]
         #:find [find #f]
         #:next-view-id [next-view-id 10]
         #:next-panel-id [next-panel-id 100]
         #:resources [resources empty-resources]
         #:placement [placement #f]
         #:input [input #f]
         #:select-drag [select-drag #f]
         #:jobs [jobs empty-job-ledger]
         #:errors [errors '()]
         #:async? [async? #f])
  (define modal
    (cond
      [input 'input]
      [placement (modal-placement placement)]
      [else #f]))
  (define pointer
    (cond
      [drag (pointer-drag drag)]
      [select-drag (pointer-select select-drag)]
      [else #f]))
  (app-state
   (editor-core plugin-states workspace-root resources layout layout-config view-scopes area
                next-view-id next-panel-id)
   (editor-session pending pending-scope quit? flash modal input pointer find
                   jobs errors async?)))

;;; ════════════════ state dispatch ════════════════

(define (state-core state)
  (cond
    [(app-state? state) (app-state-editor state)]
    [(editor-core? state) state]
    [else
     (raise-argument-error 'state-core "app-state? or editor-core?" state)]))

(define (state-session state)
  (cond
    [(app-state? state) (app-state-session state)]
    [(editor-core? state) #f]
    [else
     (raise-argument-error 'state-session "app-state? or editor-core?" state)]))

(define empty-session
  (editor-session '() #f #f "" #f #f #f #f empty-job-ledger '() #f))

(define (session-of state)
  (or (state-session state) empty-session))

(define (state-with-core state core)
  (cond
    [(app-state? state) (struct-copy app-state state [editor core])]
    [else core]))

(define (state-with-session state session)
  (cond
    [(app-state? state) (struct-copy app-state state [session session])]
    [else
     (error 'state-with-session
            "session 字段只存在于 app-state，收到：~a" state)]))

;;; ════════════════ core accessor / update ════════════════

(define (state-plugin-states state)
  (editor-core-plugin-states (state-core state)))
(define (state-workspace-root state)
  (editor-core-workspace-root (state-core state)))
(define (state-resources state)
  (editor-core-resources (state-core state)))
(define (state-layout state)
  (editor-core-layout (state-core state)))
(define (state-layout-config state)
  (editor-core-layout-config (state-core state)))
(define (state-view-scopes state)
  (editor-core-view-scopes (state-core state)))
(define (state-area state)
  (editor-core-area (state-core state)))
(define (state-next-view-id state)
  (editor-core-next-view-id (state-core state)))
(define (state-next-panel-id state)
  (editor-core-next-panel-id (state-core state)))

(define (state-with-plugin-states state plugin-states)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [plugin-states plugin-states])))
(define (state-with-workspace-root state workspace-root)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [workspace-root workspace-root])))
(define (state-with-resources state resources)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [resources resources])))
(define (state-with-layout state layout)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [layout layout])))
(define (state-with-layout-config state layout-config)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [layout-config layout-config])))
(define (state-with-view-scopes state view-scopes)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [view-scopes view-scopes])))
(define (state-with-area state area)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [area area])))
(define (state-with-next-view-id state next-view-id)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [next-view-id next-view-id])))
(define (state-with-next-panel-id state next-panel-id)
  (state-with-core
   state
   (struct-copy editor-core (state-core state)
                [next-panel-id next-panel-id])))

;;; ════════════════ session accessor / update ════════════════

(define (state-pending state)
  (editor-session-pending (session-of state)))
(define (state-pending-scope state)
  (editor-session-pending-scope (session-of state)))
(define (state-quit? state)
  (editor-session-quit? (session-of state)))
(define (state-flash state)
  (editor-session-flash (session-of state)))
(define (state-drag state)
  (define p (editor-session-pointer (session-of state)))
  (and (pointer-drag? p) (pointer-drag-value p)))
(define (state-select-drag state)
  (define p (editor-session-pointer (session-of state)))
  (and (pointer-select? p) (pointer-select-value p)))
(define (state-find state)
  (editor-session-find (session-of state)))
(define (state-placement state)
  (define m (editor-session-modal (session-of state)))
  (and (modal-placement? m) (modal-placement-value m)))
(define (state-input state)
  (define s (session-of state))
  (and (eq? (editor-session-modal s) 'input)
       (editor-session-input s)))
(define (state-input-seed state)
  (editor-session-input (session-of state)))
(define (state-jobs state)
  (editor-session-jobs (session-of state)))
(define (state-errors state)
  (editor-session-errors (session-of state)))
(define (state-async? state)
  (editor-session-async? (session-of state)))

(define (update-session state f)
  (state-with-session state (f (session-of state))))

(define (state-with-pending state pending)
  (update-session state (λ (s) (struct-copy editor-session s [pending pending]))))
(define (state-with-pending-scope state pending-scope)
  (update-session state (λ (s) (struct-copy editor-session s [pending-scope pending-scope]))))
(define (state-clear-pending state)
  (if (and (null? (state-pending state))
           (not (state-pending-scope state)))
      state
      (state-with-pending-scope
       (state-with-pending state '()) #f)))
(define (state-with-quit state quit?)
  (update-session state (λ (s) (struct-copy editor-session s [quit? quit?]))))
(define (state-with-flash state text)
  (update-session state (λ (s) (struct-copy editor-session s [flash text]))))
(define (state-clear-flash state)
  (if (string=? (state-flash state) "")
      state
      (state-with-flash state "")))
(define (state-with-drag state drag)
  (update-session
   state
   (λ (s)
     (define p (editor-session-pointer s))
     (define p*
       (cond
         [drag (pointer-drag drag)]
         [(pointer-drag? p) #f]
         [else p]))
     (struct-copy editor-session s [pointer p*]))))
(define (state-with-select-drag state select-drag)
  (update-session
   state
   (λ (s)
     (define p (editor-session-pointer s))
     (define p*
       (cond
         [select-drag (pointer-select select-drag)]
         [(pointer-select? p) #f]
         [else p]))
     (struct-copy editor-session s [pointer p*]))))
(define (state-with-find state find)
  (update-session state (λ (s) (struct-copy editor-session s [find find]))))
(define (state-with-placement state placement)
  (update-session
   state
   (λ (s)
     (define m (editor-session-modal s))
     (define m*
       (cond
         [placement (modal-placement placement)]
         [(modal-placement? m) #f]
         [else m]))
     (struct-copy editor-session s [modal m*]))))
(define (state-with-input state input)
  (update-session
   state
   (λ (s)
     (define m (editor-session-modal s))
     (define m*
       (cond
         [input 'input]
         [(eq? m 'input) #f]
         [else m]))
     (struct-copy editor-session s [modal m*] [input input]))))
(define (state-with-jobs state jobs)
  (update-session state (λ (s) (struct-copy editor-session s [jobs jobs]))))
(define (state-with-errors state errors)
  (update-session state (λ (s) (struct-copy editor-session s [errors errors]))))
(define (state-with-async state async?)
  (update-session state (λ (s) (struct-copy editor-session s [async? async?]))))

;;; ════════════════ plugin-state ════════════════

(define (state-plugin-state state owner)
  (hash-ref (state-plugin-states state) owner #f))

(define (state-set-plugin-state state owner value)
  (state-with-plugin-states
   state
   (hash-set (state-plugin-states state) owner value)))

;;; ════════════════ resource 查询 ════════════════

(define (state-resource-for-view state vid)
  (and vid (resources-find-view (state-resources state) vid)))

(define (state-resource-for-doc state did)
  (and did (resources-find-doc (state-resources state) did)))

(define (state-doc-mode state did)
  (define r (state-resource-for-doc state did))
  (and r (resource-mode r)))

(define (state-opened-paths state)
  (resources-opened-paths (state-resources state)))

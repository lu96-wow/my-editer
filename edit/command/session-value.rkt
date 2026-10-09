#lang racket

;;; edit/command/session-value.rkt —— 会话值（纯）
;;;
;;; session 及其附属值（panel / prompt）的定义、构造、纯字段变换，
;;; 以及 file-map 包装。不 require core editor、不 require tui、不涉及渲染。
;;;
;;; 上层：
;;;   session-core.rkt    core 边界（文档 / 视图 / 几何 / 渲染 / 读）
;;;   session-window.rkt  状态窗口 + 输入行 + 命令处理链 + refresh
;;;   session-edit.rkt    焦点 / 结构手术 / 操作原语
;;;   session-mouse.rkt   鼠标
;;;   session.rkt         聚合出口

(require "../core/layout.rkt"      ; layout-fill
         "../core/focus.rkt"       ; focus-target
         "../core/doc-state.rkt")

;;; ---------- 值 ----------

;; 状态窗口：一块停靠视图 + 内容生成函数 + 自己的键表。
(struct panel (id vid refresh keys group) #:transparent)
;; id      : symbol
;; refresh : (session -> (or/c document #f))   ; #f = 不自动刷新（如输入行）
;; group   : symbol | #f   同一组（同位置）互斥；#f = 独占一行的窗口

;; 输入行状态。
(struct prompt (vid label on-submit) #:transparent)
;; on-submit : (session string -> session)

(struct session
  (ed layout bindings presentations panels
   focus edit-vid width height quit? keys doc-keymaps handlers prompt prefix docs)
  #:transparent)
;; ed            : core editor（文档 / 视图真身仓）
;; layout        : 布局具体树（装配后 slot 已填；叶子是 vid）
;; bindings      : slot-id -> node（装配期声明，留作 slot 查询）
;; presentations : (hash vid -> boolean)   显隐（缺省 = 可见）
;; panels        : (listof panel)
;; focus         : focus（输入焦点）
;; edit-vid      : 活动编辑视图（粘性）
;; width height  : 屏幕尺寸
;; quit?         : 退出标志
;; keys          : (listof keymap)  全局键表叠
;; doc-keymaps   : (hash did -> keymap)
;; handlers      : (listof (session cmd -> (or/c session #f)))  命令处理链
;; prompt        : prompt | #f
;; prefix        : prefix | #f   活动前缀（多键序列）
;; docs          : doc-state     did <-> path + 保存句柄（脏标记）

(provide (struct-out session) (struct-out panel) (struct-out prompt)
         session-new session-assemble
         session-visible? session-set-visible
         session-focus-vid session-set-prefix
         ;; 状态窗口查询（纯）
         session-panel session-panel-vid session-vid-keys session-dock-vid? session-add-panel
         ;; file-map 包装 + 保存句柄（doc-state）
         session-docs session-file-path session-file-did session-file-dids
         session-set-file session-clear-doc
         session-saved session-set-saved session-clear-doc)

;;; ---------- 构造 / 纯变换 ----------

(define (session-new ed layout bindings focus width height [keys '()])
  (session ed layout bindings (hash) '()
           focus (focus-target focus) width height #f keys (hash) '() #f #f
           (doc-state-empty)))

;; 装配：用 bindings 把 layout 里的 slot 洞填成具体子树。
(define (session-assemble s layout bindings)
  (struct-copy session s [layout (layout-fill layout bindings)] [bindings bindings]))

;;; ---------- 展示态（显隐） ----------

(define (session-visible? s vid) (hash-ref (session-presentations s) vid #t))
(define (session-set-visible s vid on?)
  (struct-copy session s [presentations (hash-set (session-presentations s) vid on?)]))

(define (session-focus-vid s) (focus-target (session-focus s)))
(define (session-set-prefix s p) (struct-copy session s [prefix p]))

;;; ---------- 状态窗口查询（纯） ----------

(define (session-panel s vid)
  (for/first ([p (in-list (session-panels s))] #:when (eqv? vid (panel-vid p))) p))
(define (session-panel-vid s id)
  (for/first ([p (in-list (session-panels s))] #:when (eq? id (panel-id p))) (panel-vid p)))
(define (session-vid-keys s vid)
  (define p (session-panel s vid))
  (and p (panel-keys p)))
(define (session-dock-vid? s vid)
  (and vid (and (session-panel s vid) #t)))
(define (session-add-panel s p)
  (struct-copy session s [panels (append (session-panels s) (list p))]))

;;; ---------- file-map 包装 ----------

;;; ---------- doc-state 包装（did <-> path + 保存句柄） ----------

(define (session-file-path s did) (doc-state-path (session-docs s) did))
(define (session-file-did s path) (doc-state-did (session-docs s) path))
(define (session-file-dids s) (doc-state-dids (session-docs s)))
(define (session-set-file s did path)
  (struct-copy session s [docs (doc-state-set-path (session-docs s) did path)]))

;;; ---------- 保存句柄 ----------

(define (session-saved s did) (doc-state-saved (session-docs s) did))
(define (session-set-saved s did h)
  (struct-copy session s [docs (doc-state-set-saved (session-docs s) did h)]))
(define (session-clear-doc s did)
  (struct-copy session s [docs (doc-state-remove (session-docs s) did)]))

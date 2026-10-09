#lang racket

;;; edit/session/value.rkt —— 会话值（纯）
;;;
;;; session 及其附属值（panel / prompt）的定义、构造、纯字段变换，
;;; 以及 file-map 包装。不 require core editor、不 require tui、不涉及渲染。
;;;
;;; 同层：
;;;   doc.rkt       文档域状态（did<->path / 保存句柄 / 文档键表）
;;;   focus.rkt     焦点 set
;;;   core.rkt      core 边界（文档 / 视图 / 几何 / 渲染 / 读）
;;;   panel.rkt     状态窗口：枚举 / 互换 / 刷新
;;;   bottom.rkt    底部区 + log 通道
;;;   prompt.rkt    输入行
;;;   structure.rkt 结构手术（显示 / 分屏 / 关闭 / 尺寸）
;;;   edit.rkt      操作原语（焦点 / 滚动 / 编辑 / 选区 / 剪贴板）
;;;   mouse.rkt     鼠标
;;;   ../session.rkt 聚合出口

(require "../core/layout.rkt"      ; layout-fill
         "../core/focus.rkt"       ; focus-target
         "../core/doc-state.rkt"
         "../core/ids.rkt")        ; slot-editor

;;; ---------- 值 ----------

;; 状态窗口：一块停靠视图 + 内容生成函数 + 自己的键表 + 声明的停靠区 / 尺寸。
(struct panel (id vid refresh keys region axis size) #:transparent)
;; id      : symbol
;; refresh : (session -> (or/c document #f))   ; #f = 不自动刷新（如输入行）
;; region  : slot-id     所在框架区域（同区域互斥 / Tab 互换 / 按 id 选中）
;; axis    : 'width | 'height   尺寸沿哪个轴
;; size    : positive-integer | 'flex   期望尺寸（'flex = 由骨架决定，不做适配）

;; 输入行状态。
(struct prompt (vid label on-submit) #:transparent)
;; on-submit : (session string -> session)

;; 浮动窗口：瞬态叠加视图（补全弹窗等）。位置 / 尺寸 / 深度由调用方算，自带键表。
(struct float (vid keys x y w h deep) #:transparent)
;; vid   : 视图（内容是真身，走 engine）
;; keys  : keymap | #f   自己的键表（优先于 document / global）
;; x y   : 屏幕绝对位置（列 / 行）
;; w h   : 尺寸
;; deep  : 深度（大 = 在上；建议远大于布局树）

(struct session
  (ed frame bindings editor layout presentations panels floats
   focus edit-vid width height quit? keys doc-keymaps handlers prompt prefix docs log)
  #:transparent)
;; ed            : core editor（文档 / 视图真身仓）
;; frame         : 骨架（config 的 slot 树；#f = 未装配）
;; bindings      : slot-id -> node（面板子树；slot-editor 由 editor 字段提供）
;; editor        : 编辑区运行时子树（起于 (blank)，由 split/close 等手术生长）
;; layout        : 派生缓存 = fill(frame, bindings + editor)；#f = 未装配
;; presentations : (hash vid -> boolean)   显隐（缺省 = 可见）
;; panels        : (listof panel)
;; floats        : (listof float)   浮动窗口（在布局树之上，不占位）
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
;; log           : (listof string)   只读日志（错误等；底部 log 面板显示）

(provide (struct-out session) (struct-out panel) (struct-out prompt) (struct-out float)
         session-new session-assemble session-set-frame
         session-visible? session-set-visible
         session-focus-vid session-set-prefix
         session-resize session-quit session-add-handler
         ;; 编辑区子树（结构手术用）
         session-editor session-set-editor
         ;; 状态窗口查询（纯）
         session-panel session-panel-vid session-vid-keys session-dock-vid? session-add-panel
         ;; 浮动窗口注册表（打开 / 关闭见 structure.rkt）
         session-floats session-float session-float-add session-float-remove
         session-float-move
         ;; doc-state 值本身（包装见 doc.rkt）
         session-docs)

;;; ---------- 构造 / 纯变换 ----------

(define (session-new ed frame bindings focus width height [keys '()])
  (session-rebuild
   (session ed frame bindings (blank) #f (hash) '() '()
            focus (focus-target focus) width height #f keys (hash) '() #f #f
            (doc-state-empty) '())))

;; 重算派生 layout：把 panel 绑定与编辑区子树填进骨架的 slot。
(define (session-rebuild s)
  (struct-copy session s
    [layout (and (session-frame s)
                 (layout-fill (session-frame s)
                              (hash-set (or (session-bindings s) (hash))
                                        slot-editor (session-editor s))))]))

;; 装配 / 换骨架：用 bindings 把 frame 里的 slot 洞填成具体子树。
;; 编辑区子树在 editor 字段，不受换骨架影响。
(define (session-assemble s frame bindings)
  (session-rebuild (struct-copy session s [frame frame] [bindings bindings])))

;; 运行时换骨架（保留编辑区与面板）。
(define (session-set-frame s frame)
  (session-rebuild (struct-copy session s [frame frame])))

;; 提交新的编辑区子树（结构手术的唯一写入口），并重算 layout。
(define (session-set-editor s editor)
  (session-rebuild (struct-copy session s [editor editor])))

;;; ---------- 展示态（显隐） ----------

(define (session-visible? s vid) (hash-ref (session-presentations s) vid #t))
(define (session-set-visible s vid on?)
  (struct-copy session s [presentations (hash-set (session-presentations s) vid on?)]))

(define (session-focus-vid s) (focus-target (session-focus s)))
(define (session-set-prefix s p) (struct-copy session s [prefix p]))

;; 会话级纯字段变换。
(define (session-resize s w h) (struct-copy session s [width w] [height h]))
(define (session-quit s) (struct-copy session s [quit? #t]))
(define (session-add-handler s h)
  (struct-copy session s [handlers (cons h (session-handlers s))]))

;;; ---------- 状态窗口查询（纯） ----------

(define (session-panel s vid)
  (for/first ([p (in-list (session-panels s))] #:when (eqv? vid (panel-vid p))) p))
(define (session-panel-vid s id)
  (for/first ([p (in-list (session-panels s))] #:when (eq? id (panel-id p))) (panel-vid p)))
(define (session-vid-keys s vid)
  (define p (session-panel s vid))
  (cond [p (panel-keys p)]
        [else (define f (session-float s vid)) (and f (float-keys f))]))
;; dock = 面板或浮层：焦点落到它们时不改变粘性 edit-vid，也不被编辑区手术当普通视图。
(define (session-dock-vid? s vid)
  (and vid (or (and (session-panel s vid) #t) (and (session-float s vid) #t))))
(define (session-add-panel s p)
  (struct-copy session s [panels (append (session-panels s) (list p))]))

;;; ---------- 浮动窗口注册表（纯） ----------

(define (session-float s vid)
  (for/first ([f (in-list (session-floats s))] #:when (eqv? vid (float-vid f))) f))
(define (session-float-add s f)
  (struct-copy session s [floats (append (session-floats s) (list f))]))
(define (session-float-remove s vid)
  (struct-copy session s
    [floats (for/list ([f (in-list (session-floats s))]
                       #:unless (eqv? vid (float-vid f))) f)]))
(define (session-float-move s vid x y)
  (struct-copy session s
    [floats (for/list ([f (in-list (session-floats s))])
              (if (eqv? vid (float-vid f)) (struct-copy float f [x x] [y y]) f))]))

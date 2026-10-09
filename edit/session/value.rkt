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

;; 叠加层（deco）：每帧由 proc 产出一组已落位视图（placed）。几何随光标变时用 deco；
;; 常值叠加窗口让 proc 返回固定 placed 即可。overlays 标记哪些 vid 是叠加层（dock / 不入缓冲区）。
(struct deco (name proc) #:transparent)
;; name : symbol
;; proc : session -> (listof placed)

;; 输入层：短暂接管输入的模态键表（补全菜单等）。栈顶在前；落空则回落到 base（fallthrough）。
(struct layer (id keys) #:transparent)
;; id   : symbol
;; keys : keymap     该层生效的键表

(struct session
  (ed frame bindings editor layout presentations panels decos overlays
   focus edit-vid width height quit? keys rules doc-keymaps handlers prompt prefix docs log
   layers plugin-bindings services hooks awaiting)
  #:transparent)
;; ed            : core editor（文档 / 视图真身仓）
;; frame         : 骨架（config 的 slot 树；#f = 未装配）
;; bindings      : slot-id -> node（面板子树；slot-editor 由 editor 字段提供）
;; editor        : 编辑区运行时子树（起于 (blank)，由 split/close 等手术生长）
;; layout        : 派生缓存 = fill(frame, bindings + editor)；#f = 未装配
;; presentations : (hash vid -> boolean)   显隐（缺省 = 可见）
;; panels        : (listof panel)
;; decos         : (listof deco)    每帧叠加层（产 placed）
;; overlays      : (listof vid)     叠加层 vid（dock / 不入缓冲区）
;; focus         : focus（输入焦点）
;; edit-vid      : 活动编辑视图（粘性）
;; width height  : 屏幕尺寸
;; quit?         : 退出标志
;; keys          : (listof keymap)  全局键表叠
;; rules         : (listof rule)    打开文件时的文档绑定规则（装配注入）
;; doc-keymaps   : (hash did -> keymap)
;; handlers      : (listof (session cmd -> (or/c session #f)))  命令处理链
;; prompt        : prompt | #f
;; prefix        : prefix | #f   活动前缀（多键序列）
;; layers        : (listof layer)  活动输入层（栈顶在前；模态键表优先，落空回落 base）
;; docs          : doc-state     did <-> path + 保存句柄（脏标记）
;; log           : (listof string)   只读日志（错误等；底部 log 面板显示）
;; plugin-bindings : (hash did -> (listof face-plugin))      document 插件绑定（插件层）
;; services        : (hash name -> any/c)   每-editor 命名状态（插件间共享 / 懒建服务）
;; hooks           : (listof hook)   生命周期通知处理器（见 hook.rkt）
;; awaiting        : (hash id -> (list token current? on-result))  异步结果闸门（见 async.rkt）

(provide (struct-out session) (struct-out panel) (struct-out prompt) (struct-out deco)
         (struct-out layer)
         session-new session-assemble session-set-frame
         session-visible? session-set-visible
         session-focus-vid session-set-prefix
         session-resize session-quit session-add-handler session-set-rules
         session-layer-push session-layer-pop session-layer-active?
         ;; 每-editor 命名状态（插件间共享 / 懒建服务）
         session-service-ref session-service-put
         ;; 编辑区子树（结构手术用）
         session-editor session-set-editor
         ;; 状态窗口查询（纯）
         session-panel session-panel-vid session-vid-keys session-dock-vid? session-add-panel
         ;; 叠加层（deco）/ 叠加 vid 登记
         session-decos session-deco-add session-deco-remove
         session-overlays session-overlay-add session-overlay-remove
         ;; doc-state 值本身（包装见 doc.rkt）
         session-docs)

;;; ---------- 构造 / 纯变换 ----------

(define (session-new ed frame bindings focus width height [keys '()])
  (session-rebuild
   (session ed frame bindings (blank) #f (hash) '() '() '()
            focus (focus-target focus) width height #f keys '() (hash) '() #f #f
            (doc-state-empty) '()
            '() (hash) (hash) '() (hash))))

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
(define (session-set-rules s rules) (struct-copy session s [rules rules]))

;;; ---------- 每-editor 命名状态 ----------

(define (session-service-ref s name) (hash-ref (session-services s) name #f))
(define (session-service-put s name v)
  (struct-copy session s [services (hash-set (session-services s) name v)]))

;;; ---------- 输入层（模态键表，栈顶在前） ----------

(define (session-layer-push s id keys)
  (struct-copy session s [layers (cons (layer id keys) (session-layers s))]))
(define (session-layer-pop s id)
  (struct-copy session s
    [layers (for/list ([l (in-list (session-layers s))]
                       #:unless (eq? id (layer-id l))) l)]))
(define (session-layer-active? s id)
  (for/or ([l (in-list (session-layers s))]) (eq? id (layer-id l))))

;;; ---------- 状态窗口查询（纯） ----------

(define (session-panel s vid)
  (for/first ([p (in-list (session-panels s))] #:when (eqv? vid (panel-vid p))) p))
(define (session-panel-vid s id)
  (for/first ([p (in-list (session-panels s))] #:when (eq? id (panel-id p))) (panel-vid p)))
(define (session-vid-keys s vid)
  (define p (session-panel s vid))
  (and p (panel-keys p)))
;; dock = 面板或叠加层 vid：焦点落到它们时不改变粘性 edit-vid。
(define (session-dock-vid? s vid)
  (and vid (or (and (session-panel s vid) #t) (and (memv vid (session-overlays s)) #t))))
(define (session-add-panel s p)
  (struct-copy session s [panels (append (session-panels s) (list p))]))

;;; ---------- 叠加层（deco）/ 叠加 vid 登记（纯） ----------

(define (session-deco-add s d)
  (struct-copy session s [decos (append (session-decos s) (list d))]))
(define (session-deco-remove s name)
  (struct-copy session s
    [decos (for/list ([d (in-list (session-decos s))] #:unless (eq? name (deco-name d))) d)]))
(define (session-overlay-add s vid)
  (struct-copy session s [overlays (cons vid (session-overlays s))]))
(define (session-overlay-remove s vid)
  (struct-copy session s [overlays (remove vid (session-overlays s))]))

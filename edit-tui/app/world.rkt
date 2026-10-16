#lang racket

;;; app/world.rkt —— 应用世界（纯数据）+ mode / ctx / 内部事件
;;;
;;; world 是编辑器的**全部逻辑状态**，全都是值：
;;;   · 布局 tree、浮窗、焦点、keytable、pending、drag…… 都是纯数据；
;;;   · core 的 view / buffer 是**不透明句柄**（在 world 里只是引用），
;;;     它们的编排完全由 world 里的数据决定。
;;;
;;; 设计取向：world 只放「逻辑状态」，不放渲染缓存 / inbox channel 这类
;;; 运行期细节 —— 那些归 loop（shell）。这样 world 可复制、可比较、可单测。
;;;
;;; 暂定清单（改这里时同步 app/README.md）：
;;;   · area 用 core 的 rect 表示（屏幕全幅 0,0,w,h）。
;;;   · status 是纯字符串；以后要富状态栏 → 换成数据 + 注册渲染器。
;;;   · modes 只带一张额外键表（栈顶优先）；on-event / on-exit / state 以后加。
;;;   · internal 是扩展点：kind → (world payload → (values world (listof intent)))。
;;;     async 回投、插件自定义内部事件都走这里，loop 不需要知道 kind。
;;;   · drag 是纯数据（seam / select 两种），所以拖拽可 headless 重放。

(require "../command/main.rkt"
         "../layout/main.rkt"
         "../../core/editor.rkt"
         "panel-ref.rkt"
         "intent.rkt")

(provide (struct-out world)
         make-world
         (struct-out mode)
         (struct-out ctx)
         (struct-out app-event)
         (struct-out drag)
         world-panels world-panel-refs world-panels+refs
         world-ref->view world-ref->panel world-focus-view
         world-resize
         world-focus-on
         world-push-mode world-pop-mode
         world-overlay-views
         world-set-status world-set-pending world-set-drag world-set-layout
         world-set-floats
         world-stop
         mark-dirty mark-clean)

;;; ════════════════ 内部事件（异步 / 外部回投） ════════════════
;;; 与 tui 的 event? 平行：inbox 里收的是它，world-step 也认它。
;;; kind 是开的 symbol；payload 任意。默认只认识 'task-done（见 step.rkt）。
(struct app-event (kind payload) #:transparent)

;;; ════════════════ 模式 ════════════════
;;; 暂定最小：只带一张额外键表。栈顶优先查表，命中即用，否则落全局表。
;;; 以后 minibuffer / which-key 都是 mode，而不是特例代码。
;;;
;;; 未来（见 app/README.md「面向未来」）：模式会并入 world 的**有序表层**
;;; （mode 层 → focus 文档类型层 → 插件覆盖层 → 全局层），支持插拔 / 覆盖 / 还原。
(struct mode (name table) #:transparent)

;;; ════════════════ ctx：命令看到的派生视图 ════════════════
;;; 由 world + event 纯派生。命令拿它做决策、产出 intent，不直接改 core。
;;; 字段：
;;;   ref       : panel-ref | #f   命令作用的**主体身份**（稳定）
;;;   view      : view | #f        由 ref 当帧解析出的 view（便利）
;;;   panel     : panel | #f       鼠标命中的 panel（每帧值）
;;;   doc-point : point | #f       鼠标位置换算出的文档点
;;; 需要 row/col/mods 时从 event 派生（(mouse-position event) 等），避免冗余。
(struct ctx (world event ref view panel doc-point) #:transparent)

;;; ════════════════ 拖动状态（纯数据） ════════════════
;;; kind    : 'seam | 'select | …   step 只解释 'seam；其余由类型命令自己解释
;;; subject : panel-ref | #f        拖动主体的**稳定身份**（决定鼠标命令用哪张
;;;                                 类型表；指针移出面板 / view 被替换都不悬空）
;;; data    : any/c                 类型自定义
;;;           seam   → (list row col cuts layout0)
;;;           select → (list ref anchor-point)
(struct drag (kind subject data) #:transparent)

;;; ════════════════ world ════════════════
(struct world
  (area        ; rect（屏幕全幅）
   layout      ; layout tree（纯）
   floats      ; (listof float)
   focus       ; panel-ref | #f      稳定的 panel 身份（不是 view 值；见 panel-ref.rkt）
   keytable    ; keytable（全局表）   ← 未来：有序表层（mode/类型/插件/全局）
   modes       ; (listof mode)（栈顶在前）
   pending     ; (listof token)   未读完的键前缀（纯数据，替代可变 matcher）
   status      ; string
   running?    ; bool
   dirty?      ; bool
   drag        ; #f | drag?   拖动状态（seam / select …）；step 只解释 kind='seam
   internal)   ; (hash/c symbol procedure)
  #:transparent)

;;; 设计提醒（见 app/README.md「面向未来」④）：
;;; world 里**长期状态**（focus / drag.subject）统一用 **panel-ref**（稳定身份），
;;; 不要存每帧重算的 panel 或可被替换的 view 值。
;;; view / panel 一律在需要时用 world-ref->view / world-ref->panel 解析。

(define (make-world #:area area
                    #:layout layout
                    #:focus [focus #f]
                    #:keytable [keytable (make-keytable)]
                    #:modes [modes '()]
                    #:floats [floats '()]
                    #:status [status ""]
                    #:internal [internal (hash)])
  (world area layout floats focus keytable modes '() status #t #f #f internal))

;;; ---------- 派生 / 更新助手（放这里，step 与 render 共用） ----------

;; 当前所有 panel：平铺 + 浮窗（浮窗 deep 高，自然在上）。
;; 命中、渲染、拖缝都用同一份，保证一致。
(define (world-panels w)
  (call-with-values (λ () (world-panels+refs w)) (λ (ps _refs) ps)))

;; 与 world-panels **严格同序**的 ref 列表（命中 panel → ref 反查用）。
(define (world-panel-refs w)
  (call-with-values (λ () (world-panels+refs w)) (λ (_ps refs) refs)))

;; 一次 solve 同时拿 panels 与同序 refs（渲染 / 命中共用，不重复解树）。
(define (world-panels+refs w)
  (define-values (placements tiled _cuts) (tree-solve (world-layout w) (world-area w)))
  (values (append tiled (floats->panels (world-floats w)))
          (placements->refs placements (world-floats w))))

;; panel-ref → 当帧 view / panel（不在布局 / 隐藏 → #f）。
(define (world-ref->view w ref)
  (and ref (ref->view (world-layout w) (world-floats w) ref)))
(define (world-ref->panel w ref)
  (and ref (ref->panel (world-layout w) (world-floats w) (world-area w) ref)))

;; 焦点 view（便利访问器；焦点是 ref，view 每次解析）。
(define (world-focus-view w) (world-ref->view w (world-focus w)))

;; resize：换 area 并标脏。cols = 宽，rows = 高。
(define (world-resize w cols rows)
  (struct-copy world w [area (rect 0 0 cols rows)] [dirty? #t]))

;; 切焦点：传 **panel-ref**；同时清 pending —— 不能跨焦点续前缀。
;; 只接受 leaf（浮窗永不占焦点）；#f = 清焦点。
;; 所有切焦点的地方（指针命令 / 兜底 / open-doc）都该走这个，别裸改 focus 字段。
(define (world-focus-on w ref)
  (if (or (not ref) (focusable-ref? ref))
      (mark-dirty (world-set-pending (struct-copy world w [focus ref]) '()))
      w))

;;; ---------- 模式栈（临时表层） ----------
;;; 栈顶优先；active-tables 把它压在 kind / 全局之上 → 临时表可「遮蔽 / 新增」。

(define (world-push-mode w m)
  (struct-copy world w [modes (cons m (world-modes w))]))

;; name → 去掉第一个同名 mode；name = #f → 弹栈顶。
(define (world-pop-mode w name)
  (define ms (world-modes w))
  (define ms*
    (cond
      [(not name) (if (null? ms) ms (cdr ms))]
      [else
       (let loop ([l ms])
         (cond [(null? l) '()]
               [(eq? (mode-name (car l)) name) (cdr l)]
               [else (cons (car l) (loop (cdr l)))]))]))
  (struct-copy world w [modes ms*]))

;;; ---------- overlay 可画视图（渲染用） ----------
;;; 需要画 overlay（光标 / 选区）的 view = 焦点 view + **拥有活动模式的浮窗 view**。
;;; mode 名 = float key（见 ops 的 open-overlay）。普通浮窗（无模式）不画 overlay，
;;; 免得静态弹窗里冒出光标。
(define (world-overlay-views w)
  (define names (for/list ([m (in-list (world-modes w))]) (mode-name m)))
  (append (if (world-focus-view w) (list (world-focus-view w)) '())
          (for/list ([fl (in-list (world-floats w))]
                     #:when (and (float-view fl) (memq (float-key fl) names)))
            (float-view fl))))

;;; ---------- 原子状态设置（纯；是否重绘由调用方 mark-dirty 决定） ----------
;;; 把「回显区 / 拖动 / 布局 / 退出」这类 world 字段的裸 struct-copy 收成命名转换，
;;; 让 step / ops 只描述“改哪个状态”，不重复拼 struct-copy。

(define (world-set-status w text) (struct-copy world w [status text]))   ; 状态行 / 提示
(define (world-set-pending w seq) (struct-copy world w [pending seq]))   ; 键前缀
(define (world-set-drag w d)      (struct-copy world w [drag d]))        ; 拖动状态（#f = 结束）
(define (world-set-layout w t)    (struct-copy world w [layout t]))      ; 布局树
(define (world-set-floats w fs)   (struct-copy world w [floats fs]))      ; 浮窗层
(define (world-stop w)            (struct-copy world w [running? #f]))   ; 退出循环

(define (mark-dirty w) (struct-copy world w [dirty? #t]))
(define (mark-clean w) (struct-copy world w [dirty? #f]))

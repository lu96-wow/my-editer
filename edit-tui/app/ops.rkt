#lang racket

;;; app/ops.rkt —— 操作「根对象」的原语层（layout / focus / document）
;;;
;;; 上层命令里不再手写 `(modify (λ (w) (struct-copy world w [layout …])))`：
;;; 调这里的命名原语即可。所有原语都是**纯构造器**：只产出 intent，不改状态、
;;; 不碰 core、不新增状态。
;;;
;;; 约定：所有原语返回 `(listof intent)`（正是命令的返回类型），于是：
;;;   单操作命令  (λ (ctx) (hide-pane 'tree))
;;;   多操作命令  (λ (ctx) (append (hide-pane 'tree) (focus-leaf 'editor)))
;;;
;;; ── 归纳：这套原语做什么 ────────────────────────────────────────────
;;;
;;;   布局结构（tree）
;;;     mount-view / clear-view   装 / 卸某 leaf 的 view
;;;     show-pane / hide-pane / toggle-pane   显隐（结构不动）
;;;     delete-pane               删 leaf（原始操作，不看 role 策略）
;;;     split-pane / move-pane / resize-seam  切分 / 移动 / 拖缝
;;;     layout-op                 任意 tree→tree（逃生舱）
;;;
;;;   切分 / 关闭（读 role 注册表，见 role.rkt）
;;;     split-left/right/up/down  把**焦点所在的 splittable leaf**切成两块，
;;;                               新块继承原 role、view=#f，焦点移过去
;;;     close-focused             按 role 的 close-policy 分派：
;;;                                 'hide → hide-pane；'delete → delete-pane；
;;;                                 'keep-last → 最后一块只 clear-view，否则 delete-pane
;;;
;;;   焦点（world.focus 是稳定 panel-ref，见 panel-ref.rkt）
;;;     focus-on ref / focus-leaf id   切焦点（清 pending）
;;;     focus-move ctx dir             面板间方向移动
;;;
;;;   文档（编辑 intent 的命名封装，底层是 edit / invoke）
;;;     insert-text / delete-backward / delete-forward / navigate / undo / redo
;;;
;;; ── 值词汇（本模块用到的） ──────────────────────────────────────────
;;;
;;;   axis        : 'lr | 'tb                    （'lr 左右并排 | 'tb 上下堆叠）
;;;   side        : 'before | 'after
;;;   dir         : 'left | 'right | 'up | 'down
;;;   leaf role   : 任意 symbol（见 role.rkt）
;;;   panel-ref   : (leaf-ref id) | (float-ref key)（见 panel-ref.rkt）

(require "../layout/main.rkt"
         "../../core/editor.rkt"
         "world.rkt"
         "panel-ref.rkt"
         "role.rkt"
         "intent.rkt")

(provide
 ;; layout（结构 / 显隐 / 切分 / 移动 / 缝）
 layout-op mount-view clear-view
 show-pane hide-pane toggle-pane delete-pane
 split-pane move-pane resize-seam
 ;; 切分 / 关闭（读 role 策略）
 splittable-leaf? split-focused
 split-left split-right split-up split-down
 close-focused
 ;; floats
 floats-op add-float remove-float
 ;; focus
 focus-on focus-leaf focus-move
 ;; document
 insert-text delete-backward delete-forward
 navigate undo redo)

;;; ════════════════════════ layout 结构 ════════════════════════

;; 通用：tree → tree 的纯变换，包成“改 world.layout”的 intent。
(define (layout-op f)
  (list (modify (λ (w) (struct-copy world w [layout (f (world-layout w))])))))

(define (mount-view id v)  (layout-op (λ (t) (tree-set-view t id v))))
(define (clear-view id)    (mount-view id #f))          ; 卸掉 view，保留 leaf（空占位）
(define (show-pane id)     (layout-op (λ (t) (tree-show t id))))
(define (hide-pane id)     (layout-op (λ (t) (tree-hide t id))))
(define (toggle-pane id)
  (layout-op (λ (t) (if (tree-visible? t id) (tree-hide t id) (tree-show t id)))))
(define (delete-pane id)   (layout-op (λ (t) (tree-close t id))))   ; 原始删除，不读 role
(define (split-pane id axis new-id #:side [side 'after] #:role [role 'panel])
  (layout-op (λ (t) (tree-split t id axis new-id #:side side #:role role))))
(define (move-pane id target axis #:side [side 'after])
  (layout-op (λ (t) (tree-move t id target axis #:side side))))
(define (resize-seam cut delta)
  (layout-op (λ (t) (tree-resize-seam t cut delta))))

;;; ════════════════════════ 切分（读 role 的 splittable?） ════════════════════════
;;;
;;; 四个原语 split-left/right/up/down 把**焦点所在的、role 声明为 splittable 的 leaf**
;;; 沿方向切成两块，产生一个新的**空块**（view=#f，**继承原 role**），焦点移过去。
;;; 非 splittable（如文件树 / 状态栏）→ no-op。默认 'editor splittable、'panel 不。

(define (splittable-leaf? l)
  (and l (role-splittable? (role-of (leaf-role l)))))

;; 焦点所在的 splittable leaf（否则 #f）。
(define (ctx-splittable-leaf ctx)
  (define w (ctx-world ctx))
  (define r (ctx-ref ctx))
  (and r (eq? (panel-ref-kind r) 'leaf)
       (let ([l (tree-find (world-layout w) (panel-ref-id r))])
         (and (splittable-leaf? l) l))))

;; 通用：在焦点 splittable leaf 旁切一块新的空块（继承 role）。axis+side 定方向。
(define (split-focused ctx axis side)
  (define l (ctx-splittable-leaf ctx))
  (cond
    [(not l) '()]                                     ; 非 splittable → 不生效
    [else
     (define role (leaf-role l))
     (define id (gensym role))
     (append (split-pane (leaf-id l) axis id #:side side #:role role)
             (focus-leaf id))]))

(define (split-left ctx)  (split-focused ctx 'lr 'before))
(define (split-right ctx) (split-focused ctx 'lr 'after))
(define (split-up ctx)    (split-focused ctx 'tb 'before))
(define (split-down ctx)  (split-focused ctx 'tb 'after))

;;; ════════════════════════ 关闭焦点面板（读 role 的 close-policy） ════════════════════════
;;;
;;; close-policy（见 role.rkt）：
;;;   'hide      只隐藏，不删（固定面板；再显示用 show-pane/toggle-pane）
;;;   'delete    直接删 leaf
;;;   'keep-last 删，除非这是**该 role 的最后一块** → 只 clear-view（保留空占位），焦点不动
;;;
;;; 默认：'panel → hide，'editor → keep-last。
;;; 不变量（keep-last）：该 role 永远至少有一块 leaf，所以之后仍能 split / open。

;; 关闭 / 隐藏 ref 后的回落目标：优先 splittable 邻居 → 任意其他邻居 → 任意 splittable → #f。
(define (fallback-ref w ref)
  (define ps (world-panels w))
  (define refs (world-panel-refs w))
  (define from (for/first ([p (in-list ps)] [rf (in-list refs)] #:when (equal? rf ref)) p))
  (define (ref-of p) (and p (for/first ([p* (in-list ps)] [rf (in-list refs)] #:when (eq? p* p)) rf)))
  (define (leaf-of r)
    (and r (eq? (panel-ref-kind r) 'leaf) (tree-find (world-layout w) (panel-ref-id r))))
  (define (splittable? r) (splittable-leaf? (leaf-of r)))
  (define nbrs (for/list ([dir (in-list '(left up right down))])
                 (and from (ref-of (panel-neighbor ps from dir)))))
  (or (for/first ([r (in-list nbrs)] #:when (splittable? r)) r)
      (for/first ([r (in-list nbrs)] #:when (and r (not (equal? r ref)))) r)
      (for/first ([l (in-list (tree-visible-leaves (world-layout w)))]
                  #:when (splittable-leaf? l))
        (leaf-ref (leaf-id l)))
      #f))

(define (count-role tree role)
  (for/sum ([l (in-list (tree-leaves tree))] #:when (eq? (leaf-role l) role)) 1))

(define (close-focused ctx)
  (define w (ctx-world ctx))
  (define ref (ctx-ref ctx))
  (define l (and ref (eq? (panel-ref-kind ref) 'leaf)
                 (tree-find (world-layout w) (panel-ref-id ref))))
  (cond
    [(not l) '()]
    [else
     (define id (leaf-id l))
     (define role (leaf-role l))
     (case (role-close-policy (role-of role))
       [(hide)   (append (hide-pane id)   (focus-on (fallback-ref w ref)))]
       [(delete) (append (delete-pane id) (focus-on (fallback-ref w ref)))]
       [(keep-last)
        (if (= 1 (count-role (world-layout w) role))
            (append (clear-view id)  (focus-on ref))            ; 最后一块：清 view，保留占位
            (append (delete-pane id) (focus-on (fallback-ref w ref))))]
       [else '()])]))

;;; ════════════════════════ floats ════════════════════════

(define (floats-op f)
  (list (modify (λ (w) (struct-copy world w [floats (f (world-floats w))])))))
(define (add-float fl)     (floats-op (λ (fs) (floats-add fs fl))))
(define (remove-float key) (floats-op (λ (fs) (floats-remove fs key))))

;;; ════════════════════════ focus ════════════════════════

;; 切到指定 panel-ref（清 pending）。返回 (listof intent)。
(define (focus-on ref)
  (list (modify (λ (w) (world-focus-on w ref)))))

;; 便捷：按 leaf id 切焦点。
(define (focus-leaf id) (focus-on (leaf-ref id)))

;; 面板间方向移动焦点：ctx.ref → 当帧 panel → panel-neighbor → 邻居 ref → focus-on。
;; 返回 (listof intent)（无邻居 → '()）。
(define (focus-move ctx dir)
  (define w (ctx-world ctx))
  (define ps (world-panels w))
  (define refs (world-panel-refs w))
  (define from (for/first ([p (in-list ps)] [rf (in-list refs)]
                           #:when (equal? rf (ctx-ref ctx))) p))
  (cond
    [(not from) '()]
    [else
     (define nbr (panel-neighbor ps from dir))
     (define nbr-ref (and nbr (for/first ([p (in-list ps)] [rf (in-list refs)]
                                          #:when (eq? p nbr)) rf)))
     (if nbr-ref (focus-on nbr-ref) '())]))

;;; ════════════════════════ document（薄封装编辑原语） ════════════════════════

(define (insert-text v text) (list (edit v (op-type text))))
(define (delete-backward v)  (list (edit v (op-backspace))))
(define (delete-forward v)   (list (edit v (op-delete))))
(define (navigate v op)      (list (invoke (λ () (op v)))))
(define (undo v)             (list (invoke (λ () (buffer-undo! (view-buffer v))))))
(define (redo v)             (list (invoke (λ () (buffer-redo! (view-buffer v))))))

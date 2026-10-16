#lang racket

;;; app/ops.rkt —— 操作「根对象」的原语层（layout / focus / document）
;;;
;;; 命里不再手写 `(modify (λ (w) (struct-copy world w [layout …])))`。
;;; 所有原语都是**纯构造器**：只产出 intent，不改状态、不碰 core、不新增状态。
;;;
;;; 约定：所有原语返回 `(listof intent)`（正是命令的返回类型），于是：
;;;   单操作命令  (λ (ctx) (hide-pane 'tree))
;;;   多操作命令  (λ (ctx) (append (hide-pane 'tree) (focus! ref)))
;;;
;;; 三类根：
;;;   layout   tree→tree / floats→floats 的纯变换，包成“改 world 根字段”的 intent
;;;   focus    改 world.focus（稳定 panel-ref）
;;;   document 编辑 intent 的命名封装（避免上层重复 op-* / invoke）
;;;
;;; 高级/任意布局改动直接用 `layout-op` 传一个 tree→tree 函数。

(require "../layout/main.rkt"
         "../../core/editor.rkt"
         "world.rkt"
         "panel-ref.rkt"
         "role.rkt"
         "intent.rkt")

(provide
 ;; layout
 layout-op mount-view
 show-pane hide-pane toggle-pane close-pane
 split-pane move-pane resize-seam
 ;; 切分（只对 splittable role 生效；见 role.rkt）
 splittable-leaf? split-editor
 split-left split-right split-up split-down
 ;; 关闭（带焦点回落）
 close-focused
 ;; floats
 floats-op add-float remove-float
 ;; focus
 focus! focus-move
 ;; document
 insert-text delete-backward delete-forward
 navigate undo redo)

;;; ════════════════════════ layout ════════════════════════

;; 通用：tree → tree 的纯变换，包成“改 world.layout”的 intent。
(define (layout-op f)
  (list (modify (λ (w) (struct-copy world w [layout (f (world-layout w))])))))

(define (mount-view leaf-id v) (layout-op (λ (t) (tree-set-view t leaf-id v))))
(define (show-pane id)         (layout-op (λ (t) (tree-show t id))))
(define (hide-pane id)         (layout-op (λ (t) (tree-hide t id))))
(define (toggle-pane id)
  (layout-op (λ (t) (if (tree-visible? t id) (tree-hide t id) (tree-show t id)))))
(define (close-pane id)        (layout-op (λ (t) (tree-close t id))))
(define (split-pane id axis new-id #:side [side 'after] #:role [role 'panel])
  (layout-op (λ (t) (tree-split t id axis new-id #:side side #:role role))))
(define (move-pane id target axis #:side [side 'after])
  (layout-op (λ (t) (tree-move t id target axis #:side side))))
(define (resize-seam cut delta)
  (layout-op (λ (t) (tree-resize-seam t cut delta))))

;;; ════════════════════════ 切分（只对 splittable role 生效） ════════════════════════
;;;
;;; 四个原语 split-left/right/up/down：把**焦点所在的、role 声明为 splittable 的 leaf**
;;; 沿方向切成两块，产生一个新的**空块**（view=#f，**继承原 role**），焦点移过去。
;;;
;;; 行为由 role 注册表决定（role.rkt）：`role-splittable? (role-config role)`。
;;; 非 splittable（如文件树/状态栏）→ no-op。默认 'editor splittable、'panel 不。
;;; 新块初始为空，用 mount-view/open-doc 装内容。

(define (splittable-leaf? l)
  (and l (role-splittable? (role-config (leaf-role l)))))

;; 焦点所在的 splittable leaf（否则 #f）。
(define (ctx-splittable-leaf ctx)
  (define w (ctx-world ctx))
  (define r (ctx-ref ctx))
  (and r (eq? (panel-ref-kind r) 'leaf)
       (let ([l (tree-find (world-layout w) (panel-ref-id r))])
         (and (splittable-leaf? l) l))))

;; 通用：在焦点 splittable leaf 旁切一块新的空块（继承 role）。axis+side 定方向。
(define (split-editor ctx axis side)
  (define l (ctx-splittable-leaf ctx))
  (cond
    [(not l) '()]                                     ; 非 splittable → 不生效
    [else
     (define role (leaf-role l))
     (define id (gensym role))
     (append (split-pane (leaf-id l) axis id #:side side #:role role)
             (focus! (leaf-ref id)))]))

(define (split-left ctx)  (split-editor ctx 'lr 'before))
(define (split-right ctx) (split-editor ctx 'lr 'after))
(define (split-up ctx)    (split-editor ctx 'tb 'before))
(define (split-down ctx)  (split-editor ctx 'tb 'after))

;;; ════════════════════════ 关闭焦点面板（行为由 role 注册表决定） ════════════════════════
;;;
;;; close 策略（见 role.rkt）：
;;;   'hide      只隐藏，不删（固定面板；再显示用 show-pane/toggle-pane）
;;;   'delete    直接删 leaf
;;;   'keep-last 删，除非这是**该 role 的最后一块** → 只清 view（保留空占位），焦点不动
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
     (case (role-close (role-config role))
       [(hide)   (append (hide-pane id)  (focus! (fallback-ref w ref)))]
       [(delete) (append (close-pane id) (focus! (fallback-ref w ref)))]
       [(keep-last)
        (if (= 1 (count-role (world-layout w) role))
            (append (mount-view id #f)   (focus! ref))   ; 最后一块：清 view，保留占位
            (append (close-pane id)      (focus! (fallback-ref w ref))))]
       [else '()])]))

;;; ════════════════════════ floats ════════════════════════

(define (floats-op f)
  (list (modify (λ (w) (struct-copy world w [floats (f (world-floats w))])))))
(define (add-float fl)     (floats-op (λ (fs) (floats-add fs fl))))
(define (remove-float key) (floats-op (λ (fs) (floats-remove fs key))))

;;; ════════════════════════ focus ════════════════════════

;; 切到指定 panel-ref（会清 pending）。
(define (focus! ref)
  (list (modify (λ (w) (world-focus-on w ref)))))

;; 面板间方向移动焦点：ctx.ref → 当帧 panel → panel-neighbor → 邻居 ref → focus!。
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
     (if nbr-ref (focus! nbr-ref) '())]))

;;; ════════════════════════ document（薄封装编辑原语） ════════════════════════

(define (insert-text v text) (list (edit v (op-type text))))
(define (delete-backward v)  (list (edit v (op-backspace))))
(define (delete-forward v)   (list (edit v (op-delete))))
(define (navigate v op)      (list (invoke (λ () (op v)))))
(define (undo v)             (list (invoke (λ () (buffer-undo! (view-buffer v))))))
(define (redo v)             (list (invoke (λ () (buffer-redo! (view-buffer v))))))

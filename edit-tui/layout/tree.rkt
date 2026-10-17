#lang racket

;;; layout/tree.rkt —— 布局树（纯）：分裂树 + 固定/弹性尺寸 + 显隐
;;;
;;; node = leaf | split
;;;   (leaf id view borders face weight dim visible? role)
;;;       id      宿主身份（focus / 移动 / 查找用；不放进 core 的 panel）
;;;       view    core 的 view | #f（空面板）
;;;       borders (listof 'up 'down 'left 'right) —— 默认全边；特殊面板自己指定
;;;       face    边框 face 符号
;;;       weight  边框 face 权重（core panel 的 weight）
;;;       dim     沿父轴的**尺寸**（见下）
;;;       visible? 显隐
;;;       role    'panel（面板，固定区域）| 'editor | 'slot | …（见 app/role.rkt）
;;;   (split axis children dim)
;;;       axis    'lr（左右并排，竖缝）| 'tb（上下堆叠，横缝）
;;;       children (listof node)  —— n 叉
;;;
;;; dim（尺寸）是 tagged union：
;;;   (fixed n)                  固定 **n 格内容**（不含自身边框；solver 自动加边框厚度）
;;;   (flex w #:min lo #:max hi) 弹性：按权重 w 分；lo/hi 是内容格上下限（#f = 不限）
;;; 数字 = (flex n)，兼容旧的 `#:size n`。
;;;
;;; 分配见 solve.rkt：固定先取，剩余按权重分给 flex（钳制 min/max）；
;;; 没有 flex 时余量给第一个孩子（让末尾固定面板贴底）。
;;;
;;; 全部操作是 (tree → tree) 纯函数，用 leaf id 定位。core 不认识树；
;;; 「树 → (listof panel)」在 solve.rkt。

(provide (struct-out leaf) (struct-out split)
         (struct-out dim)
         fixed flex ->dim dim-fixed? dim-flex?
         node? node-dim node-visible? node-with-dim
         make-leaf empty-tree
         tree-find tree-leaves tree-visible-leaves tree-contains?
         tree-set-view tree-set-dim tree-set-weight tree-set-borders tree-set-face tree-set-visible
         tree-set-role
         tree-show tree-hide tree-visible?
         tree-split tree-close tree-move
         tree-detach tree-insert
         tree-resize-at)

(require racket/list
         "../../core/view/panel.rkt")          ; borders-all

(define (borders-default) borders-all)

;;; ---------- 尺寸 ----------

(struct dim (kind value lo hi) #:transparent)
;; kind 'fixed : value = 内容格数（nat）；lo/hi 忽略
;; kind 'flex  : value = 权重（>0）；lo/hi = 内容 min/max（#f | nat）

(define (fixed n) (dim 'fixed (max 0 (inexact->exact (floor n))) #f #f))
(define (flex w #:min [lo #f] #:max [hi #f]) (dim 'flex w lo hi))
(define (->dim x) (if (dim? x) x (flex x)))
(define (dim-fixed? d) (eq? (dim-kind d) 'fixed))
(define (dim-flex? d)  (eq? (dim-kind d) 'flex))

;;; ---------- 节点 ----------

(struct leaf (id view borders face weight dim visible? role) #:transparent)
(struct split (axis children dim) #:transparent)

(define (node? x) (or (leaf? x) (split? x)))
(define (node-dim n) (->dim (if (leaf? n) (leaf-dim n) (split-dim n))))
;; 可见性只在叶子上；分组节点“可见” = 至少有一个可见叶子（全隐藏的分组不占空间）。
(define (node-visible? n)
  (cond [(leaf? n) (leaf-visible? n)]
        [else (for/or ([c (in-list (split-children n))]) (node-visible? c))]))
(define (node-with-dim n d)
  (define d* (->dim d))
  (if (leaf? n) (struct-copy leaf n [dim d*]) (struct-copy split n [dim d*])))

;; 空布局（没有叶子）。
(define (empty-tree) (split 'lr '() (flex 1)))

;; #:size 接受数字（= flex 权重）或 dim。
(define (make-leaf id view #:borders [borders (borders-default)] #:face [face 'window-border]
                   #:weight [weight 0] #:size [size 1] #:visible? [visible? #t]
                   #:role [role 'panel])
  (leaf id view borders face weight (->dim size) visible? role))

;;; ---------- 查 ----------

(define (tree-find t id)
  (cond [(leaf? t) (and (eqv? (leaf-id t) id) t)]
        [else (for/or ([c (in-list (split-children t))]) (tree-find c id))]))

(define (tree-contains? t id)
  (cond [(leaf? t) (eqv? (leaf-id t) id)]
        [else (for/or ([c (in-list (split-children t))]) (tree-contains? c id))]))

(define (tree-leaves t)
  (cond [(leaf? t) (list t)]
        [else (append* (for/list ([c (in-list (split-children t))]) (tree-leaves c)))]))

;; 可见叶（隐藏叶跳过）。
(define (tree-visible-leaves t)
  (cond [(leaf? t) (if (leaf-visible? t) (list t) '())]
        [else (append* (for/list ([c (in-list (split-children t))]) (tree-visible-leaves c)))]))

(define (tree-visible? t id)
  (define l (tree-find t id))
  (and l (leaf-visible? l)))

;;; ---------- 逐叶改字段 ----------

(define (map-leaves t f)
  (cond [(leaf? t) (f t)]
        [else (struct-copy split t [children (map (λ (c) (map-leaves c f)) (split-children t))])]))

(define (tree-set-view t id view) (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [view view]) l))))
(define (tree-set-dim t id d)      (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [dim (->dim d)]) l))))
(define (tree-set-weight t id w)   (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [weight w]) l))))
(define (tree-set-borders t id b)  (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [borders b]) l))))
(define (tree-set-face t id f)     (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [face f]) l))))
(define (tree-set-visible t id v)  (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [visible? v]) l))))
(define (tree-set-role t id r)     (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [role r]) l))))
(define (tree-show t id) (tree-set-visible t id #t))
(define (tree-hide t id) (tree-set-visible t id #f))

;;; ---------- 插入（split / move 共用）----------

;; 把 node 插到 target 叶旁边：若 target 的父 split 与 axis 同向且 target 是直接孩子，
;; 作为同层兄弟插入（n 叉不加深）；否则把 target 叶替换成 (split axis [target node])。
;; 新块用 flex 1（wrap）/ 继承 target 的 dim（同轴兄弟）。
(define (tree-insert t target axis node #:side [side 'after])
  (define (go n)
    (cond
      [(leaf? n)
       (if (eqv? (leaf-id n) target)
           (let ([base (node-with-dim n (flex 1))]
                 [ins  (node-with-dim node (flex 1))])
             (split axis (if (eq? side 'after) (list base ins) (list ins base))
                    (leaf-dim n)))
           n)]
      [else
       (if (and (eq? axis (split-axis n))
                (for/or ([c (in-list (split-children n))]) (and (leaf? c) (eqv? (leaf-id c) target))))
           (struct-copy split n
                        [children
                         (append*
                          (for/list ([c (in-list (split-children n))])
                            (if (and (leaf? c) (eqv? (leaf-id c) target))
                                (let ([ins (node-with-dim node (node-dim c))])
                                  (if (eq? side 'after) (list c ins) (list ins c)))
                                (list c))))])
           (struct-copy split n [children (map go (split-children n))]))]))
  (go t))

(define (tree-split t target axis id
                    #:view [view #f] #:borders [borders (borders-default)]
                    #:face [face 'window-border] #:weight [weight 0]
                    #:side [side 'after] #:role [role 'panel])
  (tree-insert t target axis (make-leaf id view #:borders borders #:face face #:weight weight #:role role)
               #:side side))

;;; ---------- 摘除（close / move 共用）----------

;; → (values 新树 被摘节点 | #f)。空 split 剪掉，单孩子 split 塌缩。
(define (tree-detach t id)
  (define removed #f)
  (define (go n)
    (cond
      [(leaf? n) (if (eqv? (leaf-id n) id) (begin (set! removed n) #f) n)]
      [else
       (define cs (filter values (map go (split-children n))))
       (cond [(null? cs) #f]
             ;; 塌缩：单孩子顶上来，并**继承 split 的 dim**（保住整棵子树的额度）
             [(null? (cdr cs)) (node-with-dim (car cs) (split-dim n))]
             [else (struct-copy split n [children cs])])]))
  (define t* (go t))
  (values (or t* (empty-tree)) removed))

(define (tree-close t id)
  (define-values (t* _) (tree-detach t id))
  t*)

(define (tree-move t id target axis #:side [side 'after])
  (cond
    ;; id / target 不在树里 → 原样（不动数据）
    [(or (not (tree-contains? t id)) (not (tree-contains? t target))) t]
    [else
     (define-values (t* moved) (tree-detach t id))
     ;; target 在被摘走的子树里（含 id = target）→ 放弃，保持原树
     (if (and moved (tree-contains? t* target))
         (tree-insert t* target axis moved #:side side)
         t)]))

;;; ---------- 拖缝：按路径改两个相邻可见孩子的 dim ----------

;; 从 i 之后找第一个可见孩子（隐藏孩子不占额度，跳过）。
(define (next-visible-index cs i)
  (for/first ([j (in-range (add1 i) (length cs))]
              #:when (node-visible? (list-ref cs j)))
    j))

;; path = 从根到 split 的孩子下标表；i = 缝左 / 上方的**可见**孩子（原始下标）。
;; 右 / 下方伙伴是 i 之后第一个**可见**孩子 —— 中间夹了隐藏孩子时，index+1 未必是它。
;; d-i / d-i+1 可以给数字（= flex 权重）或 dim。
(define (tree-resize-at t path i d-i d-i+1)
  (define di (->dim d-i)) (define dj (->dim d-i+1))
  (define (go n path)
    (define cs (split-children n))
    (cond
      [(null? path)
       (define j (next-visible-index cs i))
       (if j
           (struct-copy split n
                        [children (list-set (list-set cs i (node-with-dim (list-ref cs i) di))
                                            j (node-with-dim (list-ref cs j) dj))])
           n)]
      [else
       (define k (car path))
       (struct-copy split n [children (list-set cs k (go (list-ref cs k) (cdr path)))])]))
  (go t path))

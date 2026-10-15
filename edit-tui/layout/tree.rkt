#lang racket

;;; layout/tree.rkt —— 布局树（纯）：分裂树 + 权重尺寸 + 显隐
;;;
;;; node = leaf | split
;;;   (leaf id view borders face weight size visible?)
;;;       id      宿主身份（focus / 移动 / 查找用；不放进 core 的 panel）
;;;       view    core 的 view | #f（空面板）
;;;       borders (listof 'up 'down 'left 'right) —— 默认全边；特殊面板自己指定
;;;       face    边框 face 符号
;;;       weight  边框 face 权重（core panel 的 weight）
;;;       size    沿父轴的**权重**（>0）
;;;       visible? 显隐
;;;   (split axis children size)
;;;       axis    'lr（左右并排，竖缝）| 'tb（上下堆叠，横缝）
;;;       children (listof node)  —— n 叉
;;;
;;; 显隐只在**叶子**上；split 是纯分组，只在至少有一个可见叶子时才占空间。
;;;
;;; 尺寸是**权重**：同层内按 size 比例分配沿轴额度（窗口 resize 自动按比例）。
;;; 隐藏的从分配里跳过，但 size 保留 → 再显示按原比例回来。
;;;
;;; 全部操作是 (tree → tree) 纯函数，用 leaf id 定位。core 不认识树；
;;; 「树 → (listof panel)」在 solve.rkt。

(provide (struct-out leaf) (struct-out split)
         node? node-size node-visible? node-with-size
         make-leaf empty-tree
         tree-find tree-leaves tree-visible-leaves tree-contains?
         tree-set-view tree-set-size tree-set-weight tree-set-borders tree-set-face tree-set-visible
         tree-show tree-hide tree-visible?
         tree-split tree-close tree-move
         tree-detach tree-insert
         tree-resize-at)

(require racket/list
         "../../core/view/panel.rkt")          ; borders-all

(define (borders-default) borders-all)

(struct leaf (id view borders face weight size visible?) #:transparent)
(struct split (axis children size) #:transparent)

(define (node? x) (or (leaf? x) (split? x)))
(define (node-size n) (if (leaf? n) (leaf-size n) (split-size n)))
;; 可见性只在叶子上；分组节点“可见” = 至少有一个可见叶子（全隐藏的分组不占空间）。
(define (node-visible? n)
  (cond [(leaf? n) (leaf-visible? n)]
        [else (for/or ([c (in-list (split-children n))]) (node-visible? c))]))
(define (node-with-size n s) (if (leaf? n) (struct-copy leaf n [size s]) (struct-copy split n [size s])))

;; 空布局（没有叶子）。
(define (empty-tree) (split 'lr '() 1))

(define (make-leaf id view #:borders [borders (borders-default)] #:face [face 'window-border]
                   #:weight [weight 0] #:size [size 1] #:visible? [visible? #t])
  (leaf id view borders face weight size visible?))

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
(define (tree-set-size t id size)    (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [size size]) l))))
(define (tree-set-weight t id w)     (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [weight w]) l))))
(define (tree-set-borders t id b)    (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [borders b]) l))))
(define (tree-set-face t id f)       (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [face f]) l))))
(define (tree-set-visible t id v)    (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [visible? v]) l))))
(define (tree-show t id) (tree-set-visible t id #t))
(define (tree-hide t id) (tree-set-visible t id #f))

;;; ---------- 插入（split / move 共用）----------

;; 把 node 插到 target 叶旁边：若 target 的父 split 与 axis 同向且 target 是直接孩子，
;; 作为同层兄弟插入（n 叉不加深）；否则把 target 叶替换成 (split axis [target node])。
(define (tree-insert t target axis node #:side [side 'after])
  (define (go n)
    (cond
      [(leaf? n)
       (if (eqv? (leaf-id n) target)
           (let ([base (node-with-size n 1)]
                 [ins  (node-with-size node 1)])
             (split axis (if (eq? side 'after) (list base ins) (list ins base))
                    (leaf-size n)))
           n)]
      [else
       (if (and (eq? axis (split-axis n))
                (for/or ([c (in-list (split-children n))]) (and (leaf? c) (eqv? (leaf-id c) target))))
           (struct-copy split n
                        [children
                         (append*
                          (for/list ([c (in-list (split-children n))])
                            (if (and (leaf? c) (eqv? (leaf-id c) target))
                                (let ([ins (node-with-size node (node-size c))])
                                  (if (eq? side 'after) (list c ins) (list ins c)))
                                (list c))))])
           (struct-copy split n [children (map go (split-children n))]))]))
  (go t))

(define (tree-split t target axis id
                    #:view [view #f] #:borders [borders (borders-default)]
                    #:face [face 'window-border] #:weight [weight 0]
                    #:side [side 'after])
  (tree-insert t target axis (make-leaf id view #:borders borders #:face face #:weight weight)
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
             [(null? (cdr cs)) (car cs)]          ; 塌缩：单孩子顶上来
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

;;; ---------- 拖缝：按路径改两个相邻可见孩子的 size ----------

;; 从 i 之后找第一个可见孩子（隐藏孩子不占额度，跳过）。
(define (next-visible-index cs i)
  (for/first ([j (in-range (add1 i) (length cs))]
              #:when (node-visible? (list-ref cs j)))
    j))

;; path = 从根到 split 的孩子下标表；i = 缝左 / 上方的**可见**孩子（原始下标）。
;; 右 / 下方伙伴是 i 之后第一个**可见**孩子 —— 中间夹了隐藏孩子时，index+1 未必是它。
(define (tree-resize-at t path i s-i s-i+1)
  (define (go n path)
    (define cs (split-children n))
    (cond
      [(null? path)
       (define j (next-visible-index cs i))
       (if j
           (struct-copy split n
                        [children (list-set (list-set cs i (node-with-size (list-ref cs i) s-i))
                                            j (node-with-size (list-ref cs j) s-i+1))])
           n)]
      [else
       (define k (car path))
       (struct-copy split n [children (list-set cs k (go (list-ref cs k) (cdr path)))])]))
  (go t path))

#lang racket

;;; model/layout.rkt —— 纯布局树（region id + 尺寸），不依赖 core
;;; layer  : model
;;; effect : 无（纯几何树）

;;; node = leaf | split
;;;   (leaf region dim visible? borders)
;;;       region  : region-id（成员表在 workspace.regions）
;;;       dim     : 沿父轴的尺寸
;;;       visible?: 显隐（隐藏不占额度）
;;;       borders : (listof 'up 'down 'left 'right) 外边框声明
;;;   (split axis children dim)
;;;       axis    : 'lr（左右并排）| 'tb（上下堆叠）
;;;       children: (listof node)
;;;       dim     : 作为父级孩子时的尺寸
;;;
;;; dim = (fixed n) | (flex w #:min lo #:max hi)
;;;   fixed 的 n 是**内容格**；solver 会另加边框厚度（见 projection/geometry）。
;;;
;;; 本模块只做结构 / 尺寸 / 显隐 / 切分 / 关闭 / 移动；
;;; 真正的格数分配、命中、拖缝在 projection/geometry.rkt。

(provide (struct-out dim)
         (struct-out leaf)
         (struct-out split)
         fixed flex ->dim dim-fixed? dim-flex?
         node? node-dim node-with-dim node-visible?
         make-leaf make-split empty-tree empty-tree?
         leaf-borders-all leaf-borders-none
         tree-find tree-leaves tree-regions tree-visible-regions
         tree-contains? tree-visible?
         tree-set-dim tree-set-visible tree-set-borders tree-show tree-hide
         tree-split tree-close tree-move
         tree-detach tree-insert)

;;; ---------- 尺寸 ----------

(struct dim (kind value lo hi) #:transparent)
;; kind 'fixed : value = 内容格数；lo/hi 忽略
;; kind 'flex  : value = 权重；lo/hi = 内容 min/max（#f | nat）

(define (fixed n) (dim 'fixed (max 0 (inexact->exact (floor n))) #f #f))
(define (flex w #:min [lo #f] #:max [hi #f]) (dim 'flex w lo hi))
(define (->dim x) (if (dim? x) x (flex x)))
(define (dim-fixed? d) (eq? (dim-kind d) 'fixed))
(define (dim-flex? d)  (eq? (dim-kind d) 'flex))

;;; ---------- 节点 ----------

(struct leaf (region dim visible? borders) #:transparent)
(struct split (axis children dim) #:transparent)

(define leaf-borders-all '(up down left right))
(define leaf-borders-none '())

(define (node? x) (or (leaf? x) (split? x)))
(define (node-dim n) (->dim (if (leaf? n) (leaf-dim n) (split-dim n))))
(define (node-visible? n)
  (cond [(leaf? n) (leaf-visible? n)]
        [else (for/or ([c (in-list (split-children n))]) (node-visible? c))]))
(define (node-with-dim n d)
  (define d* (->dim d))
  (if (leaf? n) (struct-copy leaf n [dim d*]) (struct-copy split n [dim d*])))

(define (make-leaf region [d 1]
                   #:visible? [visible? #t]
                   #:borders [borders leaf-borders-all])
  (leaf region (->dim d) visible? borders))

(define (make-split axis children [d 1])
  (split axis children (->dim d)))

;; 空布局 = 没有孩子的 split（唯一的“没有内容”表示）。
;; 用谓词而不是让调用方去 pair? 探 split-children。
(define (empty-tree) (split 'lr '() (flex 1)))
(define (empty-tree? n) (and (split? n) (null? (split-children n))))

;;; ---------- 查 ----------

(define (tree-find t rid)
  (cond [(leaf? t) (and (equal? (leaf-region t) rid) t)]
        [else (for/or ([c (in-list (split-children t))]) (tree-find c rid))]))

(define (tree-contains? t rid) (and (tree-find t rid) #t))

(define (tree-leaves t)
  (cond [(leaf? t) (list t)]
        [else (append* (for/list ([c (in-list (split-children t))]) (tree-leaves c)))]))

(define (tree-regions t) (map leaf-region (tree-leaves t)))

(define (tree-visible-leaves t)
  (cond [(leaf? t) (if (leaf-visible? t) (list t) '())]
        [else (append* (for/list ([c (in-list (split-children t))])
                         (tree-visible-leaves c)))]))

(define (tree-visible-regions t) (map leaf-region (tree-visible-leaves t)))

(define (tree-visible? t rid)
  (define l (tree-find t rid))
  (and l (leaf-visible? l)))

;;; ---------- 逐叶改字段 ----------

(define (map-leaves t f)
  (cond [(leaf? t) (f t)]
        [else
         (struct-copy split t
                      [children (map (λ (c) (map-leaves c f))
                                     (split-children t))])]))

(define (tree-set-dim t rid d)
  (map-leaves t (λ (l) (if (equal? (leaf-region l) rid)
                           (struct-copy leaf l [dim (->dim d)])
                           l))))
(define (tree-set-visible t rid v)
  (map-leaves t (λ (l) (if (equal? (leaf-region l) rid)
                           (struct-copy leaf l [visible? v])
                           l))))
(define (tree-set-borders t rid bs)
  (map-leaves t (λ (l) (if (equal? (leaf-region l) rid)
                           (struct-copy leaf l [borders bs])
                           l))))
(define (tree-show t rid) (tree-set-visible t rid #t))
(define (tree-hide t rid) (tree-set-visible t rid #f))

;;; ---------- 插入 / 切分 ----------

;; 把 node 插到 target 叶旁边：
;;   · 若 target 的父 split 与 axis 同向且 target 是直接孩子 → 同层兄弟（n 叉，不加深）；
;;   · 否则把 target 叶替换成 (split axis [target node])。
;; 同层兄弟继承 target 的 dim；新包一层时双方都用 flex 1。
;;
;; → (values 新树 inserted?)
;;   inserted? = #f 表示 target 不在树里：返回的树与入参相同。
;;   **装配动作必须检查这个值** —— 以前静默 no-op 会造成“region 已登记但布局里没有”。
(define (tree-insert t target axis node #:side [side 'after])
  (define found? #f)
  (define (hit!)
    (set! found? #t))
  (define (go n)
    (cond
      [(leaf? n)
       (if (equal? (leaf-region n) target)
           (begin
             (hit!)
             (let ([base (node-with-dim n (flex 1))]
                   [ins  (node-with-dim node (flex 1))])
               (split axis (if (eq? side 'after) (list base ins) (list ins base))
                      (leaf-dim n))))
           n)]
      [else
       (if (and (eq? axis (split-axis n))
                (for/or ([c (in-list (split-children n))])
                  (and (leaf? c) (equal? (leaf-region c) target))))
           (begin
             (hit!)
             (struct-copy
              split n
              [children
               (append*
                (for/list ([c (in-list (split-children n))])
                  (if (and (leaf? c) (equal? (leaf-region c) target))
                      (let ([ins (node-with-dim node (node-dim c))])
                        (if (eq? side 'after) (list c ins) (list ins c)))
                      (list c))))]))
           (struct-copy split n [children (map go (split-children n))]))]))
  (define t* (go t))
  (values t* found?))

;; → (values 新树 inserted?)（语义同 tree-insert）
(define (tree-split t target axis region
                    #:dim [d 1]
                    #:visible? [visible? #t]
                    #:borders [borders leaf-borders-all]
                    #:side [side 'after])
  (tree-insert t target axis
               (make-leaf region d #:visible? visible? #:borders borders)
               #:side side))

;;; ---------- 摘除 / 关闭 / 移动 ----------

;; → (values 新树 被摘节点 | #f)。
;; 空 split 剪掉；单孩子 split 塌缩，并继承 split 的 dim（保住子树额度）。
(define (tree-detach t rid)
  (define removed #f)
  (define (go n)
    (cond
      [(leaf? n) (if (equal? (leaf-region n) rid)
                     (begin (set! removed n) #f)
                     n)]
      [else
       (define cs (filter values (map go (split-children n))))
       (cond [(null? cs) #f]
             [(null? (cdr cs)) (node-with-dim (car cs) (split-dim n))]
             [else (struct-copy split n [children cs])])]))
  (define t* (go t))
  (values (or t* (empty-tree)) removed))

(define (tree-close t rid)
  (define-values (t* _) (tree-detach t rid))
  t*)

(define (tree-move t rid target axis #:side [side 'after])
  (cond
    [(or (not (tree-contains? t rid)) (not (tree-contains? t target))) t]
    [else
     (define-values (t* moved) (tree-detach t rid))
     (cond
       [(not (and moved (tree-contains? t* target))) t]
       [else
        ;; 这里 target 一定在树里；仍走 ok? 以便将来 tree-insert 语义变化时立刻显形。
        (define-values (t** ok?) (tree-insert t* target axis moved #:side side))
        (if ok? t** t)])]))

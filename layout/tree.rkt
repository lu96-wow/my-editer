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
;;;   (split axis children size visible?)
;;;       axis    'lr（左右并排，竖缝）| 'tb（上下堆叠，横缝）
;;;       children (listof node)  —— n 叉
;;;
;;; 尺寸是**权重**：同层内按 size 比例分配沿轴额度（窗口 resize 自动按比例）。
;;; 隐藏的从分配里跳过，但 size 保留 → 再显示按原比例回来。
;;;
;;; 全部操作是 (tree → tree) 纯函数，用 leaf id 定位。core 不认识树；
;;; 「树 → (listof panel)」在 solve.rkt。

(provide (struct-out leaf) (struct-out split)
         node? node-size node-visible? node-with-size node-with-visible
         make-leaf empty-tree
         tree-find tree-leaves tree-visible-leaves tree-contains?
         tree-set-content tree-set-size tree-set-weight tree-set-borders tree-set-face
         tree-show tree-hide tree-visible?
         tree-split tree-close tree-move
         tree-detach tree-insert
         tree-resize-at)

(require racket/list
         "../core/view/panel.rkt")          ; borders-all

(define (borders-default) borders-all)

(struct leaf (id view borders face weight size visible?) #:transparent)
(struct split (axis children size visible?) #:transparent)

(define (node? x) (or (leaf? x) (split? x)))
(define (node-size n) (if (leaf? n) (leaf-size n) (split-size n)))
(define (node-visible? n) (if (leaf? n) (leaf-visible? n) (split-visible? n)))
(define (node-with-size n s) (if (leaf? n) (struct-copy leaf n [size s]) (struct-copy split n [size s])))
(define (node-with-visible n v) (if (leaf? n) (struct-copy leaf n [visible? v]) (struct-copy split n [visible? v])))

;; 空布局（没有叶子）。
(define (empty-tree) (split 'lr '() 1 #t))

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

;; 可见叶（整棵隐藏子树都跳过）。
(define (tree-visible-leaves t)
  (cond [(leaf? t) (if (leaf-visible? t) (list t) '())]
        [(split-visible? t) (append* (for/list ([c (in-list (split-children t))]) (tree-visible-leaves c)))]
        [else '()]))

(define (tree-visible? t id)
  (define l (tree-find t id))
  (and l (leaf-visible? l)))

;;; ---------- 逐叶改字段 ----------

(define (map-leaves t f)
  (cond [(leaf? t) (f t)]
        [else (struct-copy split t [children (map (λ (c) (map-leaves c f)) (split-children t))])]))

(define (tree-set-content t id view) (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [view view]) l))))
(define (tree-set-size t id size)    (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [size size]) l))))
(define (tree-set-weight t id w)     (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [weight w]) l))))
(define (tree-set-borders t id b)    (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [borders b]) l))))
(define (tree-set-face t id f)       (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [face f]) l))))
(define (tree-show t id) (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [visible? #t]) l))))
(define (tree-hide t id) (map-leaves t (λ (l) (if (eqv? (leaf-id l) id) (struct-copy leaf l [visible? #f]) l))))

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
                    (leaf-size n) (leaf-visible? n)))
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
  (define-values (t* moved) (tree-detach t id))
  (if moved (tree-insert t* target axis moved #:side side) t))

;;; ---------- 拖缝：按路径改两个相邻孩子的 size ----------

;; path = 从根到 split 的孩子下标表；i = 缝在 children 里的左/上孩子下标。
(define (tree-resize-at t path i s-i s-i+1)
  (define (go n path)
    (define cs (split-children n))
    (cond
      [(null? path)
       (struct-copy split n
                    [children (list-set (list-set cs i (node-with-size (list-ref cs i) s-i))
                                        (add1 i) (node-with-size (list-ref cs (add1 i)) s-i+1))])]
      [else
       (define j (car path))
       (struct-copy split n [children (list-set cs j (go (list-ref cs j) (cdr path)))])]))
  (go t path))

(module+ test
  (require rackunit)
  (define t1 (tree-split (make-leaf 'editor #f) 'editor 'lr 'tree #:side 'before))
  (define (ids t) (map leaf-id (tree-leaves t)))

  ;; 结构
  (check-true (leaf? (tree-find t1 'editor)))
  (check-equal? (ids t1) '(tree editor))
  (check-true (tree-contains? t1 'tree))
  (check-false (tree-contains? t1 'nope))

  ;; 同轴再插：n 叉，不加深
  (define t2 (tree-split t1 'editor 'lr 'status #:side 'after))
  (check-equal? (ids t2) '(tree editor status))
  (check-equal? (split-axis t2) 'lr)
  (check-equal? (length (split-children t2)) 3)

  ;; 异轴插：嵌套
  (define t3 (tree-split t2 'editor 'tb 'console #:side 'after))
  (check-equal? (ids t3) '(tree editor console status))

  ;; 关闭：删叶子 + 单孩子 split 塔缩
  (define t4 (tree-close t3 'editor))
  (check-equal? (ids t4) '(tree console status))

  ;; 摘除
  (define-values (t5 removed) (tree-detach t3 'status))
  (check-equal? (ids t5) '(tree editor console))
  (check-true (leaf? removed))
  (check-eq? (leaf-id removed) 'status)

  ;; 移动：tree 拂到 editor 旁边（tb 同轴插入）
  (define t6 (tree-move t3 'tree 'editor 'tb #:side 'after))
  (check-equal? (ids t6) '(editor tree console status))

  ;; 显隐：隐藏保留 size，恢复回来
  (define t7 (tree-hide t2 'tree))
  (check-false (tree-visible? t7 'tree))
  (check-equal? (leaf-size (tree-find t7 'tree)) (leaf-size (tree-find t2 'tree)))
  (check-equal? (map leaf-id (tree-visible-leaves t7)) '(editor status))
  (check-equal? (ids (tree-show t7 'tree)) '(tree editor status))

  ;; 改字段
  (check-equal? (leaf-view (tree-find (tree-set-content t2 'tree 'v) 'tree)) 'v)
  (check-equal? (leaf-weight (tree-find (tree-set-weight t2 'tree 9) 'tree)) 9)

  ;; 拖缝：按路径改两个相邻孩子的 size
  (define t8 (tree-resize-at t2 '() 0 5 7))
  (check-equal? (leaf-size (tree-find t8 'tree)) 5)
  (check-equal? (leaf-size (tree-find t8 'editor)) 7)

  (displayln "layout/tree.rkt: ok"))

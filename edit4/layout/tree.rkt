#lang racket

;;; edit4/layout/tree.rkt —— 布局树（结构 + min + 手术）
;;;
;;;   leaf  = (id min)                  id 不透明；min = (cons min-w min-h) >= (1 . 1)
;;;   split = (axis gutter kids)        axis = 'h（左右并排）| 'v（上下堆叠）
;;;   child = (size node)               size = 边的尺寸意图（basis/elastic?）
;;;
;;; min 只存叶子；split 的 min 是**导出**的（node-min）。
;;; 本模块不认识矩形/几何/命中，只做纯树变换。

(provide (struct-out leaf) (struct-out split) (struct-out child)
         node-min axis-min
         ids path-of node-at modify-path node-edit
         split-leaf remove-leaf insert-side insert-adjacent
         set-sizes fresh-id)

(require "size.rkt" racket/list)

(struct leaf (id min) #:transparent)
(struct split (axis gutter kids) #:transparent)
(struct child (size node) #:transparent)

;;; ---------- min ----------

;; node-min : node -> (cons w h)
(define (node-min n)
  (cond
    [(not n) (cons 0 0)]
    [(leaf? n) (leaf-min n)]
    [else
     (define g (split-gutter n))
     (define ms (map (lambda (c) (node-min (child-node c))) (split-kids n)))
     (define sep (* (max 0 (sub1 (length ms))) g))
     (case (split-axis n)
       [(h) (cons (+ (for/sum ([m (in-list ms)]) (car m)) sep)
                  (apply max (map cdr ms)))]
       [(v) (cons (apply max (map car ms))
                  (+ (for/sum ([m (in-list ms)]) (cdr m)) sep))]
       [else (error 'node-min "坏 axis: ~a" (split-axis n))])]))

(define (axis-min n axis)
  (define m (node-min n))
  (if (eq? axis 'h) (car m) (cdr m)))

;;; ---------- 查询 / 定位 ----------

(define (ids n)
  (cond
    [(not n) '()]
    [(leaf? n) (list (leaf-id n))]
    [else (append* (for/list ([c (in-list (split-kids n))]) (ids (child-node c))))]))

;; 分配新 id：现有整数 id 的最大值 +1。
(define (fresh-id n)
  (add1 (for/fold ([m -1]) ([id (in-list (ids n))])
          (if (and (integer? id) (> id m)) id m))))

;; path = (listof index)；找不到 → #f
(define (path-of n id)
  (cond
    [(not n) #f]
    [(leaf? n) (and (eqv? id (leaf-id n)) '())]
    [else
     (for/or ([c (in-list (split-kids n))] [i (in-naturals)])
       (define p (path-of (child-node c) id))
       (and p (cons i p)))]))

(define (node-at n path)
  (cond
    [(not n) #f]
    [(null? path) n]
    [(leaf? n) #f]
    [else (node-at (child-node (list-ref (split-kids n) (car path))) (cdr path))]))

;;; ---------- 通用变换 ----------

;; 在 path 处替换节点（f : node -> node）。
(define (modify-path n path f)
  (cond
    [(not n) n]
    [(null? path) (f n)]
    [(leaf? n) n]
    [else
     (define i (car path))
     (split (split-axis n) (split-gutter n)
            (for/list ([c (in-list (split-kids n))] [j (in-naturals)])
              (if (= i j)
                  (child (child-size c) (modify-path (child-node c) (cdr path) f))
                  c)))]))

;; 自底向上对每个节点跑一次 f（f : node -> node）。
(define (node-edit n f)
  (f (cond
       [(not n) n]
       [(leaf? n) n]
       [else
        (split (split-axis n) (split-gutter n)
               (for/list ([c (in-list (split-kids n))])
                 (child (child-size c) (node-edit (child-node c) f))))])))

;;; ---------- 手术 ----------

(define (fresh-child node axis) (child (size (axis-min node axis) #t) node))

;; 把 id 的叶子换成 (原 | new)；side = 'before（new 在前）| 'after（new 在后）。
(define (split-leaf n id axis side new)
  (node-edit n
             (lambda (node)
               (cond
                 [(and (leaf? node) (eqv? id (leaf-id node)))
                  (define a (fresh-child node axis))
                  (define b (fresh-child new axis))
                  (split axis 1 (if (eq? side 'before) (list b a) (list a b)))]
                 [else node]))))

;; 摘掉 id 的叶子；只剩一个孩子的 split 收拢。全空 → #f。
(define (remove-leaf n id)
  (define (go node)
    (cond
      [(leaf? node) (if (eqv? id (leaf-id node)) #f node)]
      [else
       (define kept
         (for/fold ([acc '()]) ([c (in-list (split-kids node))])
           (define cn (go (child-node c)))
           (if cn (append acc (list (child (child-size c) cn))) acc)))
       (cond
         [(null? kept) #f]
         [(null? (cdr kept)) (child-node (car kept))]   ; 收拢
         [else (split (split-axis node) (split-gutter node) kept)])]))
  (go n))

;; 用一个新 split 包住整棵树，把新节点贴到某一边（区域用）。
;; side = 'left | 'right | 'top | 'bottom；new-size 是新节点的尺寸意图。
(define (insert-side n side new-size new-node)
  (define axis (if (memq side '(left right)) 'h 'v))
  (define first? (memq side '(left top)))
  (define a (child (size (axis-min n axis) #t) n))     ; 原树可伸缩
  (define b (child new-size new-node))
  (split axis 1 (if first? (list b a) (list a b))))

;; 贴到某个窗格旁（区域用，anchor 'main）：同轴则插到父 split，异轴则包住 target。
(define (insert-adjacent n target side new-size new-node)
  (define axis (if (memq side '(left right)) 'h 'v))
  (define first? (memq side '(left top)))
  (define (wrap node)
    (define a (child (size (axis-min node axis) #t) node))
    (define b (child new-size new-node))
    (split axis 1 (if first? (list b a) (list a b))))
  (define (go node)
    (cond
      [(not node) node]
      [(leaf? node) (if (eqv? target (leaf-id node)) (wrap node) node)]
      [else
       (define kids (split-kids node))
       (define g (split-gutter node))
       (define idx (for/first ([c (in-list kids)] [i (in-naturals)]
                               #:when (and (leaf? (child-node c))
                                           (eqv? target (leaf-id (child-node c)))))
                    i))
       (cond
         [idx
          (define before (take kids idx))
          (define mid (list-ref kids idx))
          (define after (drop kids (add1 idx)))
          (define new-c (child new-size new-node))
          (if (eq? (split-axis node) axis)
              (split axis g (if first? (append before (list new-c mid) after)
                                  (append before (list mid new-c) after)))
              (split (split-axis node) g
                     (append before (list (child (child-size mid) (wrap (child-node mid)))) after)))]
         [else
          (split (split-axis node) g
                 (for/list ([c (in-list kids)])
                   (if (memv target (ids (child-node c)))
                       (child (child-size c) (go (child-node c)))
                       c)))])]))
  (go n))

;;; ---------- 改尺寸（拖拽用） ----------

;; 把 path 处 split 的所有孩子的 basis 设为 sizes（elastic? 不变）。
;; 拖拽后保持 Σsizes = content，于是下一次求解走精确快路径、其它项完全不动。
(define (set-sizes n path sizes)
  (modify-path n path
               (lambda (node)
                 (if (split? node)
                     (split (split-axis node) (split-gutter node)
                            (for/list ([c (in-list (split-kids node))] [s (in-list sizes)])
                              (child (size s (size-elastic? (child-size c))) (child-node c))))
                     node))))

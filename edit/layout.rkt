#lang racket

;;; edit/layout.rkt —— 统一布局核心（可嵌套）
;;;
;;; 一种节点，递归嵌套。声明式骨架、运行时动态布局、编辑区分屏都是同一套节点：
;;;
;;;     (leaf view)                     叶子：一个 view（自带放置字段）
;;;     (slot id)                       命名洞：运行时由 bindings 填成 view 或子树
;;;     (split axis parts)              分区   axis = 'lr | 'tb；parts = [(size . node)]
;;;     (stack nodes)                   叠放（浮层；z 顺序 = 列表顺序）
;;;     (at x y w h node)               浮层定位（相对父的偏移）
;;; size = nat | 'flex
;;;
;;; 核心（唯一）：
;;;     (layout-place node bindings area) -> (listof view)     ; 纯；view 已设 rect
;;;
;;;   · 预先声明的结构 = config 拼的节点树，用 slot 留洞。
;;;   · 运行时动态布局 = 把洞绑成一棵子树（子树里可再含洞）；或直接对树做 split/remove/…
;;;   · 显隐看 view.visible?（隐藏不占位，空间自动给 flex）。
;;;   · 尺寸在 split 的 parts 里（nat 固定 / 'flex 吃剩余）。
;;;
;;; 编辑区操作（split/remove/replace/swap/resize）就是对这棵树的手术；frame 不再单独存在。

(require "area.rkt" "view.rkt")

;;; ---------- 节点 ----------

(struct leaf  (view) #:transparent)
(struct slot  (id) #:transparent)
(struct split (axis parts) #:transparent)
(struct stack (nodes) #:transparent)
(struct at    (x y w h node) #:transparent)

(provide
 (struct-out leaf) (struct-out slot) (struct-out split)
 (struct-out stack) (struct-out at)
 layout-place layout-slots
 layout-contains? layout-find layout-view layout-map-views
 layout-split layout-remove layout-replace layout-swap layout-resize)

;;; ---------- 查询 ----------

(define (layout-slots node)
  (cond
    [(not node) '()]
    [(leaf? node) '()]
    [(slot? node) (list (slot-id node))]
    [(stack? node) (append* (for/list ([c (in-list (stack-nodes node))]) (layout-slots c)))]
    [(at? node) (layout-slots (at-node node))]
    [(split? node) (append* (for/list ([p (in-list (split-parts node))]) (layout-slots (cdr p))))]
    [else (error 'layout-slots "未知节点: ~a" node)]))

(define (layout-contains? node vid)
  (cond
    [(not node) #f]
    [(leaf? node) (eqv? vid (view-id (leaf-view node)))]
    [(slot? node) #f]
    [(stack? node) (for/or ([c (in-list (stack-nodes node))]) (layout-contains? c vid))]
    [(at? node) (layout-contains? (at-node node) vid)]
    [(split? node) (for/or ([p (in-list (split-parts node))]) (layout-contains? (cdr p) vid))]
    [else #f]))

(define (layout-find node vid)
  (cond
    [(not node) #f]
    [(leaf? node) (and (eqv? vid (view-id (leaf-view node))) node)]
    [(slot? node) #f]
    [(stack? node) (for/or ([c (in-list (stack-nodes node))]) (layout-find c vid))]
    [(at? node) (layout-find (at-node node) vid)]
    [(split? node) (for/or ([p (in-list (split-parts node))]) (layout-find (cdr p) vid))]
    [else #f]))

(define (layout-view node vid)
  (define l (layout-find node vid))
  (and l (leaf-view l)))

;; 对每个叶子的 view 施加 f（换 id / 滚动 / 显隐等）。
(define (layout-map-views node f)
  (cond
    [(not node) #f]
    [(leaf? node) (leaf (f (leaf-view node)))]
    [(slot? node) node]
    [(stack? node) (struct-copy stack node
                     [nodes (for/list ([c (in-list (stack-nodes node))]) (layout-map-views c f))])]
    [(at? node) (struct-copy at node [node (layout-map-views (at-node node) f)])]
    [(split? node) (struct-copy split node
                     [parts (for/list ([p (in-list (split-parts node))])
                              (cons (car p) (layout-map-views (cdr p) f)))])]
    [else node]))

;;; ---------- 核心：求值 → 已放置的 view ----------

(define (layout-place node bindings doc-of area)
  (place-node node bindings doc-of area))

(define (place-node node bindings doc-of a)
  (cond
    [(not node) '()]
    [(leaf? node)
     (define v (leaf-view node))
     (if (view-visible? v)
         (list (view-set-rect v (doc-of (view-did v)) (area-x a) (area-y a) (area-w a) (area-h a)))
         '())]
    [(slot? node)
     (define b (hash-ref bindings (slot-id node) #f))
     (if b (place-node b bindings doc-of a) '())]
    [(stack? node)
     (append* (for/list ([c (in-list (stack-nodes node))]) (place-node c bindings doc-of a)))]
    [(at? node)
     (place-node (at-node node) bindings doc-of
                 (area (+ (area-x a) (at-x node)) (+ (area-y a) (at-y node))
                       (at-w node) (at-h node)))]
    [(split? node)
     (define horiz? (eq? (split-axis node) 'lr))
     (define dim (if horiz? (area-w a) (area-h a)))
     (define vis (for/list ([p (in-list (split-parts node))]
                            #:when (node-visible? (cdr p) bindings))
                   p))
     (define sizes (alloc-sizes vis dim))
     (define-values (_ out)
       (for/fold ([off 0] [out '()]) ([p (in-list vis)] [sz (in-list sizes)])
         (define sub (if horiz?
                         (area (+ (area-x a) off) (area-y a) sz (area-h a))
                         (area (area-x a) (+ (area-y a) off) (area-w a) sz)))
         (values (+ off sz) (append out (place-node (cdr p) bindings doc-of sub)))))
     out]
    [else (error 'layout-place "未知节点: ~a" node)]))

;; 子树里有没有可见内容（没有就不占位）。
(define (node-visible? node bindings)
  (cond
    [(not node) #f]
    [(leaf? node) (view-visible? (leaf-view node))]
    [(slot? node) (define b (hash-ref bindings (slot-id node) #f))
                  (and b (node-visible? b bindings))]
    [(stack? node) (for/or ([c (in-list (stack-nodes node))]) (node-visible? c bindings))]
    [(at? node) (node-visible? (at-node node) bindings)]
    [(split? node) (for/or ([p (in-list (split-parts node))]) (node-visible? (cdr p) bindings))]
    [else #f]))

;; 一组 parts 在维长 dim 下的实际尺寸（fixed 取自身，flex 均分剩余，余数给最后一个 flex）。
(define (alloc-sizes parts dim)
  (define fixed (for/sum ([p (in-list parts)] #:when (not (eq? 'flex (car p)))) (car p)))
  (define flex-n (for/sum ([p (in-list parts)] #:when (eq? 'flex (car p))) 1))
  (define avail (max 0 (- dim fixed)))
  (define share (if (zero? flex-n) 0 (quotient avail flex-n)))
  (define last-flex (- avail (* share (sub1 flex-n))))
  (define-values (off* out* fl*)
    (for/fold ([off 0] [out '()] [fl flex-n]) ([p (in-list parts)])
      (define is-flex (eq? 'flex (car p)))
      (define want (cond [(not is-flex) (car p)]
                         [(= fl 1) last-flex]
                         [else share]))
      (define sz (max 0 (min want (max 0 (- dim off)))))
      (values (+ off sz) (append out (list sz)) (if is-flex (sub1 fl) fl))))
  out*)

;;; ---------- 编辑区手术（纯树重写） ----------

;; 分屏：把 vid 的叶换成 split(axis, [旧 leaf, 新 leaf])。size = 旧那一项的尺寸。
(define (layout-split node vid axis new-view [size 'flex])
  (define (go n)
    (cond
      [(not n) (leaf new-view)]
      [(leaf? n) (if (eqv? vid (view-id (leaf-view n)))
                     (split axis (list (cons size n) (cons 'flex (leaf new-view))))
                     n)]
      [(slot? n) n]
      [(stack? n) (struct-copy stack n [nodes (for/list ([c (in-list (stack-nodes n))]) (go c))])]
      [(at? n) (struct-copy at n [node (go (at-node n))])]
      [(split? n) (struct-copy split n
                    [parts (for/list ([p (in-list (split-parts n))]) (cons (car p) (go (cdr p))))])]
      [else n]))
  (go node))

;; 删视图；split 只剩一项就收拢。
(define (layout-remove node vid)
  (cond
    [(not node) #f]
    [(leaf? node) (and (not (eqv? vid (view-id (leaf-view node)))) node)]
    [(slot? node) node]
    [(at? node) (define c (layout-remove (at-node node) vid))
                (and c (struct-copy at node [node c]))]
    [(split? node)
     (define ps (filter values
                        (for/list ([p (in-list (split-parts node))])
                          (define c (layout-remove (cdr p) vid))
                          (and c (cons (car p) c)))))
     (cond [(null? ps) #f]
           [(null? (cdr ps)) (cdar ps)]
           [else (struct-copy split node [parts ps])])]
    [(stack? node)
     (define ns (filter values (for/list ([c (in-list (stack-nodes node))]) (layout-remove c vid))))
     (and (pair? ns) (struct-copy stack node [nodes ns]))]
    [else #f]))

;; 把 vid 的叶整体替换成 new-node。
(define (layout-replace node vid new-node)
  (cond
    [(not node) #f]
    [(leaf? node) (if (eqv? vid (view-id (leaf-view node))) new-node node)]
    [(slot? node) node]
    [(stack? node) (struct-copy stack node
                     [nodes (for/list ([c (in-list (stack-nodes node))]) (layout-replace c vid new-node))])]
    [(at? node) (struct-copy at node [node (layout-replace (at-node node) vid new-node)])]
    [(split? node) (struct-copy split node
                     [parts (for/list ([p (in-list (split-parts node))])
                              (cons (car p) (layout-replace (cdr p) vid new-node)))])]
    [else node]))

;; 交换两个 view 的位置。
(define (layout-swap node v1 v2)
  (define vv1 (layout-view node v1))
  (define vv2 (layout-view node v2))
  (cond
    [(or (not vv1) (not vv2)) node]
    [else
     (define (go n)
       (cond
         [(not n) #f]
         [(leaf? n) (define id (view-id (leaf-view n)))
                    (cond [(eqv? id v1) (leaf vv2)]
                          [(eqv? id v2) (leaf vv1)]
                          [else n])]
         [(slot? n) n]
         [(stack? n) (struct-copy stack n [nodes (for/list ([c (in-list (stack-nodes n))]) (go c))])]
         [(at? n) (struct-copy at n [node (go (at-node n))])]
         [(split? n) (struct-copy split n
                          [parts (for/list ([p (in-list (split-parts n))]) (cons (car p) (go (cdr p))))])]
         [else n]))
     (go node)]))

;; 调整 vid 所在、最近的同向 split 里那一项的尺寸。axis : 'width | 'height。
(define (layout-resize node vid axis delta reg)
  (define target (if (eq? axis 'width) 'lr 'tb))
  (define (go n a)
    (cond
      [(not n) (values #f #f)]
      [(or (leaf? n) (slot? n)) (values n #f)]
      [(stack? n)
       (define-values (ns h)
         (for/fold ([ns '()] [h #f]) ([c (in-list (stack-nodes n))])
           (define-values (c* h*) (go c a))
           (values (append ns (list c*)) (or h h*))))
       (values (struct-copy stack n [nodes ns]) h)]
      [(at? n)
       (define sub (area (+ (area-x a) (at-x n)) (+ (area-y a) (at-y n)) (at-w n) (at-h n)))
       (define-values (c* h) (go (at-node n) sub))
       (values (struct-copy at n [node c*]) h)]
      [(split? n)
       (define horiz? (eq? (split-axis n) 'lr))
       (define parts (split-parts n))
       (define dim (if horiz? (area-w a) (area-h a)))
       (define idx (for/first ([p (in-list parts)] [i (in-naturals)]
                               #:when (layout-contains? (cdr p) vid)) i))
       (cond
         [(not idx) (values n #f)]
         [(eq? (split-axis n) target)
          (define sizes (alloc-sizes parts dim))
          (define new (max 1 (min (max 1 (sub1 dim)) (+ (list-ref sizes idx) delta))))
          (define parts* (for/list ([p (in-list parts)] [i (in-naturals)])
                           (if (= i idx) (cons new (cdr p)) p)))
          (values (struct-copy split n [parts parts*]) #t)]
         [else
          (define sizes (alloc-sizes parts dim))
          (define subs
            (for/fold ([subs '()] [off 0]) ([sz (in-list sizes)])
              (define sub (if horiz?
                              (area (+ (area-x a) off) (area-y a) sz (area-h a))
                              (area (area-x a) (+ (area-y a) off) (area-w a) sz)))
              (values (append subs (list sub)) (+ off sz))))
          (define-values (c* h) (go (cdr (list-ref parts idx)) (list-ref subs idx)))
          (define parts* (for/list ([p (in-list parts)] [i (in-naturals)])
                           (if (= i idx) (cons (car p) c*) p)))
          (values (struct-copy split n [parts parts*]) h)])]
      [else (values n #f)]))
  (define-values (n* _) (go node reg))
  n*)

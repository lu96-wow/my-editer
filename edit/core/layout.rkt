#lang racket

;;; edit/core/layout.rkt —— 统一布局核心（可嵌套）
;;;
;;; 布局**只算几何**，不持 view 真身，叶子是 vid 引用：
;;;
;;;     (leaf vid)                      叶子：一个视图引用
;;;     (slot id)                       命名洞：运行时由 bindings 填成 node
;;;     (blank)                         占位但不产视图（如空编辑器区）
;;;     (split axis parts)              分区   axis = 'lr | 'tb；parts = [(size . node)]
;;;     (stack nodes)                   叠放（浮层；z 顺序 = 列表顺序）
;;;     (at x y w h node)               浮层定位（相对父的偏移）
;;; size = nat | 'flex
;;;
;;; 求值： (layout-place node bindings visible? area) -> (listof placed)
;;;   · 预先声明的结构 = config 拼的树，用 slot 留洞；运行时把洞绑成子树。
;;;   · visible? : vid -> bool（隐藏的 vid 不占位，空间自动给 flex）。
;;;   · placed = 摊平后已落位的视图（vid + 屏幕矩形）。
;;;
;;; 编辑区操作（split/remove/replace/swap/resize）就是对这棵树的手术。

(require "area.rkt")

;;; ---------- 节点 ----------

(struct leaf  (vid) #:transparent)
(struct slot  (id) #:transparent)
;; 占位节点：参与尺寸分配（所以后面的固定尺寸部分仍贴在原位），但不产视图。
(struct blank () #:transparent)
(struct split (axis parts) #:transparent)
(struct stack (nodes) #:transparent)
(struct at    (x y w h node) #:transparent)

;; 摊平结果：一个已落位的视图引用。deep 大 = 在上（stack 里靠后者抬高）。
(struct placed (vid x y w h deep) #:transparent)

(provide
 (struct-out leaf) (struct-out slot) (struct-out split)
 (struct-out stack) (struct-out at) (struct-out blank) (struct-out placed)
 layout-place layout-slots
 layout-contains? layout-fill layout-vids layout-replace-first-blank
 layout-split layout-remove layout-replace layout-resize)

;;; ---------- 查询 ----------

(define (layout-slots node)
  (cond
    [(not node) '()]
    [(leaf? node) '()]
    [(blank? node) '()]
    [(slot? node) (list (slot-id node))]
    [(stack? node) (append* (for/list ([c (in-list (stack-nodes node))]) (layout-slots c)))]
    [(at? node) (layout-slots (at-node node))]
    [(split? node) (append* (for/list ([p (in-list (split-parts node))]) (layout-slots (cdr p))))]
    [else (error 'layout-slots "未知节点: ~a" node)]))

(define (layout-contains? node vid)
  (cond
    [(not node) #f]
    [(leaf? node) (eqv? vid (leaf-vid node))]
    [(blank? node) #f]
    [(slot? node) #f]
    [(stack? node) (for/or ([c (in-list (stack-nodes node))]) (layout-contains? c vid))]
    [(at? node) (layout-contains? (at-node node) vid)]
    [(split? node) (for/or ([p (in-list (split-parts node))]) (layout-contains? (cdr p) vid))]
    [else #f]))

;; 用 bindings 把 slot 洞填成子树（装配期用），得到具体布局树。
(define (layout-fill node bindings)
  (cond
    [(not node) #f]
    [(leaf? node) node]
    [(blank? node) node]
    [(slot? node) (define b (hash-ref bindings (slot-id node) #f))
                  (if b (layout-fill b bindings) node)]
    [(stack? node) (struct-copy stack node
                     [nodes (for/list ([c (in-list (stack-nodes node))]) (layout-fill c bindings))])]
    [(at? node) (struct-copy at node [node (layout-fill (at-node node) bindings)])]
    [(split? node) (struct-copy split node
                     [parts (for/list ([p (in-list (split-parts node))])
                              (cons (car p) (layout-fill (cdr p) bindings)))])]
    [else node]))

;; 子树里所有叶视图的 vid。
(define (layout-vids node)
  (cond
    [(not node) '()]
    [(leaf? node) (list (leaf-vid node))]
    [(blank? node) '()]
    [(slot? node) '()]
    [(stack? node) (append* (for/list ([c (in-list (stack-nodes node))]) (layout-vids c)))]
    [(at? node) (layout-vids (at-node node))]
    [(split? node) (append* (for/list ([p (in-list (split-parts node))]) (layout-vids (cdr p))))]
    [else '()]))

;;; ---------- 核心：求值 → (vid . area) ----------
(define (layout-place node bindings visible? area)
  (place-node node bindings visible? area 0))

(define (place-node node bindings visible? a [deep 0])
  (cond
    [(not node) '()]
    [(leaf? node) (if (visible? (leaf-vid node))
                      (list (placed (leaf-vid node)
                                    (area-x a) (area-y a) (area-w a) (area-h a) deep))
                      '())]
    [(blank? node) '()]
    [(slot? node)
     (define b (hash-ref bindings (slot-id node) #f))
     (if b (place-node b bindings visible? a deep) '())]
    [(stack? node)
     ;; 叠放：靠后的子节点叠在上面（deep 递增）；位置相同。
     (append* (for/list ([c (in-list (stack-nodes node))] [i (in-naturals)])
                (place-node c bindings visible? a (+ deep i))))]
    [(at? node)
     (place-node (at-node node) bindings visible?
                 (area (+ (area-x a) (at-x node)) (+ (area-y a) (at-y node))
                       (at-w node) (at-h node))
                 deep)]
    [(split? node)
     (define horiz? (eq? (split-axis node) 'lr))
     (define dim (if horiz? (area-w a) (area-h a)))
     (define vis (for/list ([p (in-list (split-parts node))]
                            #:when (node-visible? (cdr p) bindings visible?))
                   p))
     (define sizes (alloc-sizes vis dim))
     (define-values (_ out)
       (for/fold ([off 0] [out '()]) ([p (in-list vis)] [sz (in-list sizes)])
         (define sub (if horiz?
                         (area (+ (area-x a) off) (area-y a) sz (area-h a))
                         (area (area-x a) (+ (area-y a) off) (area-w a) sz)))
         (values (+ off sz) (append out (place-node (cdr p) bindings visible? sub deep)))))
     out]
    [else (error 'layout-place "未知节点: ~a" node)]))

;; 子树里有没有可见内容（没有就不占位）。
(define (node-visible? node bindings visible?)
  (cond
    [(not node) #f]
    [(leaf? node) (visible? (leaf-vid node))]
    [(blank? node) #t]
    [(slot? node) (define b (hash-ref bindings (slot-id node) #f))
                  (and b (node-visible? b bindings visible?))]
    [(stack? node) (for/or ([c (in-list (stack-nodes node))]) (node-visible? c bindings visible?))]
    [(at? node) (node-visible? (at-node node) bindings visible?)]
    [(split? node) (for/or ([p (in-list (split-parts node))]) (node-visible? (cdr p) bindings visible?))]
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

;; 分屏：把 vid 的叶换成 split(axis, [旧 leaf, 新 leaf])。
(define (layout-split node vid axis new-vid [size 'flex])
  (define (go n)
    (cond
      [(not n) (leaf new-vid)]
      [(leaf? n) (if (eqv? vid (leaf-vid n))
                     (split axis (list (cons size n) (cons 'flex (leaf new-vid))))
                     n)]
      [(blank? n) n]
      [(slot? n) n]
      [(stack? n) (struct-copy stack n [nodes (for/list ([c (in-list (stack-nodes n))]) (go c))])]
      [(at? n) (struct-copy at n [node (go (at-node n))])]
      [(split? n) (struct-copy split n
                    [parts (for/list ([p (in-list (split-parts n))]) (cons (car p) (go (cdr p))))])]
      [else n]))
  (go node))

;; 删 vid；split 只剩一项就收拢。
(define (layout-remove node vid)
  (cond
    [(not node) #f]
    [(leaf? node) (and (not (eqv? vid (leaf-vid node))) node)]
    [(blank? node) node]
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
    [(leaf? node) (if (eqv? vid (leaf-vid node)) new-node node)]
    [(blank? node) node]
    [(slot? node) node]
    [(stack? node) (struct-copy stack node
                     [nodes (for/list ([c (in-list (stack-nodes node))]) (layout-replace c vid new-node))])]
    [(at? node) (struct-copy at node [node (layout-replace (at-node node) vid new-node)])]
    [(split? node) (struct-copy split node
                     [parts (for/list ([p (in-list (split-parts node))])
                              (cons (car p) (layout-replace (cdr p) vid new-node)))])]
    [else node]))

;; 调整 vid 所在、最近的同向 split 里那一项的尺寸。axis : 'width | 'height。
(define (layout-resize node vid axis delta reg)
  (define target (if (eq? axis 'width) 'lr 'tb))
  (define (go n a)
    (cond
      [(not n) (values #f #f)]
      [(or (leaf? n) (slot? n) (blank? n)) (values n #f)]
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
         [else
          (let ()
            (define sizes (alloc-sizes parts dim))
            (define-values (subs _off)
              (for/fold ([subs '()] [off 0]) ([sz (in-list sizes)])
                (define sub (if horiz?
                                (area (+ (area-x a) off) (area-y a) sz (area-h a))
                                (area (area-x a) (+ (area-y a) off) (area-w a) sz)))
                (values (append subs (list sub)) (+ off sz))))
            ;; 先往深里找：最近的同向 split 优先；子层没处理才在本层 resize。
            (define-values (c* h) (go (cdr (list-ref parts idx)) (list-ref subs idx)))
            (define parts* (for/list ([p (in-list parts)] [i (in-naturals)])
                             (if (= i idx) (cons (car p) c*) p)))
            (cond
              [h (values (struct-copy split n [parts parts*]) #t)]
              [(and (eq? (split-axis n) target) (>= (length parts) 2))
               (let* ([new (max 1 (min (max 1 (sub1 dim)) (+ (list-ref sizes idx) delta)))]
                      [parts** (for/list ([p (in-list parts*)] [i (in-naturals)])
                                 (if (= i idx) (cons new (cdr p)) p))])
                 (values (struct-copy split n [parts parts**]) #t))]
              [else (values (struct-copy split n [parts parts*]) #f)]))])]
      [else (values n #f)]))
  (define-values (n* _) (go node reg))
  n*)

;; 把第一个 blank 替换成 new-node（把视图放进空编辑器区）；没有 blank 则原样返回。
(define (layout-replace-first-blank node new-node)
  (define (go n)                       ; → (values n' done?)
    (cond
      [(not n) (values n #f)]
      [(blank? n) (values new-node #t)]
      [(leaf? n) (values n #f)]
      [(slot? n) (values n #f)]
      [(at? n) (define-values (c d) (go (at-node n)))
               (values (if d (struct-copy at n [node c]) n) d)]
      [(stack? n)
       (define-values (ns d)
         (for/fold ([ns '()] [d #f]) ([c (in-list (stack-nodes n))])
           (cond [d (values (append ns (list c)) #t)]
                 [else (define-values (c* d*) (go c))
                       (values (append ns (list c*)) d*)])))
       (values (if d (struct-copy stack n [nodes ns]) n) d)]
      [(split? n)
       (define-values (ps d)
         (for/fold ([ps '()] [d #f]) ([p (in-list (split-parts n))])
           (cond [d (values (append ps (list p)) #t)]
                 [else (define-values (c* d*) (go (cdr p)))
                       (values (append ps (list (cons (car p) c*))) d*)])))
       (values (if d (struct-copy split n [parts ps]) n) d)]
      [else (values n #f)]))
  (define-values (n* _) (go node))
  n*)

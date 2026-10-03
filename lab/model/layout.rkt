#lang racket

;;; lab/model/layout.rkt —— 分屏树布局代数（纯数据，不 require core）
;;;
;;;   pane   = id ⊕ content         叶子：显示什么（view 或固定面板）
;;;   leaf   = pane
;;;   split  = dir ⊕ children ⊕ sizes
;;;            dir     : 'row（左右排）| 'col（上下排）
;;;            sizes   : (listof size)，与 children 等长
;;;   size   = (fixed n) 固定 n 列/行 | (flex w) 按权重分剩余
;;;
;;; 求值 `layout-rects` 把树摊成屏幕格位；隐藏的叶子被跳过并把空间让给兄弟。
;;; 全部纯函数，不碰 session / core。

(provide
 ;; ---------- 类型 ----------
 (struct-out view-ref)
 (struct-out pane)
 (struct-out leaf)
 (struct-out split)
 (struct-out fixed)
 (struct-out flex)
 (struct-out pane-rect)

 ;; ---------- 构造 ----------
 view-pane file-tree-pane split-of

 ;; ---------- 求值 / 查询 ----------
 layout-rects layout-ids layout-has-visible? layout-find layout-neighbor
 layout-hit pane-ids

 ;; ---------- 结构操作 ----------
 layout-replace layout-remove layout-split-pane layout-append)

;;; ---------- 数据 ----------

;; 叶子内容：指向某视图。
(struct view-ref (vid) #:transparent)

;; 叶子：id 是身份（editor pane 用 vid，固定面板用 'file-tree 这样的符号）。
(struct pane (id content) #:transparent)

(struct leaf (pane) #:transparent)
(struct split (dir children sizes) #:transparent)
(struct fixed (n) #:transparent)
(struct flex (weight) #:transparent)

;; 求值产物：叶子在屏幕上的格位。
(struct pane-rect (id x y w h) #:transparent)

;;; ---------- 构造 ----------

(define (view-pane vid) (leaf (pane vid (view-ref vid))))
(define (file-tree-pane) (leaf (pane 'file-tree 'file-tree)))

(define (split-of dir children [sizes #f])
  (split dir children (or sizes (make-list (length children) (flex 1)))))

;;; ---------- 查询 ----------

(define (pane-ids node) (layout-ids node))

(define (layout-ids node)
  (cond
    [(null? node) '()]
    [(leaf? node) (list (pane-id (leaf-pane node)))]
    [(split? node) (append* (for/list ([c (in-list (split-children node))]) (layout-ids c)))]
    [else (error 'layout-ids "非法布局节点: ~a" node)]))

(define (layout-has-visible? node visible?)
  (cond
    [(null? node) #f]
    [(leaf? node) (and (visible? (pane-id (leaf-pane node))) #t)]
    [(split? node) (for/or ([c (in-list (split-children node))]) (layout-has-visible? c visible?))]
    [else (error 'layout-has-visible? "非法布局节点: ~a" node)]))

(define (layout-find node id)
  (cond
    [(null? node) #f]
    [(leaf? node) (and (equal? (pane-id (leaf-pane node)) id) node)]
    [(split? node)
     (for/or ([c (in-list (split-children node))]) (layout-find c id))]
    [else (error 'layout-find "非法布局节点: ~a" node)]))

;;; ---------- 求值：树 → 屏幕格位 ----------

;; root × 区域 × 分隔 → (listof pane-rect)。
;; visible? 为假的叶子不占空间；兄弟分走它让出的空间。
(define (layout-rects root x y w h [gap 1] [visible? (lambda (_) #t)])
  (eval-node root x y (max 0 w) (max 0 h) gap visible?))

(define (eval-node node x y w h gap visible?)
  (cond
    [(null? node) '()]
    [(leaf? node)
     (define id (pane-id (leaf-pane node)))
     (if (visible? id) (list (pane-rect id x y w h)) '())]
    [(split? node)
     (define dir (split-dir node))
     (define children (split-children node))
     (define sizes (split-sizes node))
     (define kept
       (for/list ([c (in-list children)] [sz (in-list sizes)]
                  #:when (layout-has-visible? c visible?))
         (cons c sz)))
     (cond
       [(null? kept) '()]
       [(null? (cdr kept)) (eval-node (car (car kept)) x y w h gap visible?)]
       [else
        (define total (if (eq? dir 'row) w h))
        (define avail (max 0 (- total (* gap (sub1 (length kept))))))
        (define lens (distribute kept avail))
        (for/fold ([acc '()] [pos (if (eq? dir 'row) x y)] #:result acc)
                  ([l (in-list lens)] [kc (in-list kept)])
          (define child (car kc))
          (define rs (if (eq? dir 'row)
                         (eval-node child pos y l h gap visible?)
                         (eval-node child x pos w l gap visible?)))
          (values (append acc rs) (+ pos l gap)))])]
    [else (error 'layout-rects "非法布局节点: ~a" node)]))

;; 把 avail 分给 kept（(child . size) 列表）：fixed 先预留，剩余按 flex 权重分，
;; 除不尽的余数补给最后一个 flex。
(define (distribute kept avail)
  (define fixed-sum
    (for/sum ([kc (in-list kept)] #:when (fixed? (cdr kc))) (fixed-n (cdr kc))))
  (define flex-weights
    (for/list ([kc (in-list kept)] #:when (flex? (cdr kc))) (flex-weight (cdr kc))))
  (define wf (apply + flex-weights))
  (define remaining (max 0 (- avail fixed-sum)))
  (define raw
    (for/list ([kc (in-list kept)])
      (define sz (cdr kc))
      (cond
        [(fixed? sz) (min (max 0 (fixed-n sz)) avail)]
        [else (if (zero? wf) 0 (floor (* remaining (/ (flex-weight sz) wf))))])))
  (define leftover (max 0 (- avail (apply + raw))))
  (define last-flex
    (for/last ([kc (in-list kept)] [i (in-naturals)] #:when (flex? (cdr kc))) i))
  (if (and last-flex (> leftover 0))
      (list-set raw last-flex (+ (list-ref raw last-flex) leftover))
      raw))

;;; ---------- 结构操作 ----------

(define (layout-replace node id new)
  (cond
    [(null? node) node]
    [(leaf? node) (if (equal? (pane-id (leaf-pane node)) id) new node)]
    [(split? node)
     (split (split-dir node)
            (for/list ([c (in-list (split-children node))]) (layout-replace c id new))
            (split-sizes node))]
    [else (error 'layout-replace "非法布局节点: ~a" node)]))

;; 删除叶子；空 split 塌缩成 '()，单子 split 塌缩成该子。
(define (layout-remove node id)
  (cond
    [(null? node) node]
    [(leaf? node) (if (equal? (pane-id (leaf-pane node)) id) '() node)]
    [(split? node)
     (define kept
       (for/list ([c (in-list (split-children node))] [sz (in-list (split-sizes node))])
         (cons (layout-remove c id) sz)))
     (define live (filter (lambda (p) (not (null? (car p)))) kept))
     (cond
       [(null? live) '()]
       [(null? (cdr live)) (car (car live))]
       [else (split (split-dir node) (map car live) (map cdr live))])]
    [else (error 'layout-remove "非法布局节点: ~a" node)]))

;; 把一个叶子换成 split（原叶子 + 新叶子）。
(define (layout-split-pane node id dir new-pane)
  (define old (layout-find node id))
  (cond
    [(not old) node]
    [else
     (layout-replace node id
                     (split dir (list old (leaf new-pane)) (list (flex 1) (flex 1))))]))

;; 追加一个叶子到树的**最右下**（沿最后一个子递归）；空树则直接成为该叶子。
(define (layout-append node new)
  (cond
    [(null? node) new]
    [(leaf? node) (split 'row (list node new) (list (flex 1) (flex 1)))]
    [(split? node)
     (define cs (split-children node))
     (split (split-dir node)
            (append (drop-right cs 1) (list (layout-append (last cs) new)))
            (split-sizes node))]
    [else (error 'layout-append "非法布局节点: ~a" node)]))

;;; ---------- 方向邻居（按几何） ----------

;; 命中测试：屏幕 (row,col) 落在哪个 pane？越界 / 空隙 → #f。（纯几何，不认识 focus）
(define (layout-hit rects row col)
  (for/first ([r (in-list rects)]
              #:when (and (>= row (pane-rect-y r))
                          (< row (+ (pane-rect-y r) (pane-rect-h r)))
                          (>= col (pane-rect-x r))
                          (< col (+ (pane-rect-x r) (pane-rect-w r)))))
    r))

;; 从 from-id 沿 dir 找最近的可聚焦 pane；无 → #f。
(define (layout-neighbor rects from-id dir)
  (define from (for/first ([r (in-list rects)] #:when (equal? (pane-rect-id r) from-id)) r))
  (and from
       (let* ([fx (pane-rect-x from)] [fy (pane-rect-y from)]
              [fw (pane-rect-w from)] [fh (pane-rect-h from)]
              [others (filter (lambda (r) (not (equal? (pane-rect-id r) from-id))) rects)]
              [cands
               (filter
                (lambda (r)
                  (case dir
                    [(left)  (<= (+ (pane-rect-x r) (pane-rect-w r)) fx)]
                    [(right) (>= (pane-rect-x r) (+ fx fw))]
                    [(up)    (<= (+ (pane-rect-y r) (pane-rect-h r)) fy)]
                    [(down)  (>= (pane-rect-y r) (+ fy fh))]
                    [else #f]))
                others)])
         (and (pair? cands)
              (let* ([cx (lambda (r) (+ (pane-rect-x r) (/ (pane-rect-w r) 2)))]
                     [cy (lambda (r) (+ (pane-rect-y r) (/ (pane-rect-h r) 2)))]
                     [fcx (+ fx (/ fw 2))] [fcy (+ fy (/ fh 2))]
                     [score (lambda (r)
                              (case dir
                                [(left right) (list (abs (- (cx r) fcx)) (abs (- (cy r) fcy)))]
                                [(up down)    (list (abs (- (cy r) fcy)) (abs (- (cx r) fcx)))]
                                [else '(0 0)]))]
                     [best (argmin (lambda (r) (apply + (score r))) cands)])
                (pane-rect-id best))))))

(define (argmin f lst)
  (for/fold ([best (car lst)] [bf (f (car lst))] #:result best) ([x (in-list (cdr lst))])
    (define fx (f x))
    (if (< fx bf) (values x fx) (values best bf))))

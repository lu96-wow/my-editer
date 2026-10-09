#lang racket

;;; edit/frame.rkt —— 框架布局（纯函数）
;;;
;;; 主区是一棵 split 树：
;;;     leaf(view)              叶子持一个 view 值
;;;     split(dir size a b)     dir = 'lr | 'tb；size = 第一段绝对格
;;;
;;; 布局是纯函数：给一块 area，递归把 rect 写进每个叶子的 view（frame 是放置的权威）。
;;; 叶子放 view 值，所以 vid 直接用 (view-id v) 拿，不需要反查表。

(require "view.rkt")

;;; ---------- 值 ----------

(struct area (x y w h) #:transparent)

(struct leaf  (view) #:transparent)
(struct split (dir size a b) #:transparent)   ; size : nat | #f（#f = 均分）
(struct frame (root) #:transparent)           ; root : #f | leaf | split

(provide
 (struct-out area)
 (struct-out leaf)
 (struct-out split)
 (struct-out frame)
 frame-empty frame-leaf
 frame-leaves frame-views frame-find frame-contains?
 frame-split frame-remove frame-replace frame-swap frame-resize
 frame-place)

;;; ---------- 构造 / 查询 ----------

(define (frame-empty) (frame #f))
(define (frame-leaf v) (frame (leaf v)))

(define (frame-leaves f)
  (define (go n)
    (cond [(not n) '()]
          [(leaf? n) (list n)]
          [else (append (go (split-a n)) (go (split-b n)))]))
  (go (frame-root f)))

(define (frame-views f)
  (for/list ([l (in-list (frame-leaves f))]) (leaf-view l)))

(define (frame-contains? f vid)
  (for/or ([l (in-list (frame-leaves f))]) (eqv? vid (view-id (leaf-view l)))))

(define (frame-find f vid)
  (for/first ([l (in-list (frame-leaves f))] #:when (eqv? vid (view-id (leaf-view l)))) l))

;;; ---------- 布局（纯）：area -> 各叶 view 的 rect ----------

(define gap 1)

(define (area-split a dir size)
  (case dir
    [(lr) (values (area (area-x a) (area-y a) size (area-h a))
                  (area (+ (area-x a) size) (area-y a) (- (area-w a) size) (area-h a)))]
    [(tb) (values (area (area-x a) (area-y a) (area-w a) size)
                  (area (area-x a) (+ (area-y a) size) (area-w a) (- (area-h a) size)))]
    [else (error 'area-split "dir 必须是 'lr / 'tb，得到 ~a" dir)]))

;; 给每个叶 view 设 x y w h（叶间留 1 格 gap）。
(define (frame-place f reg)
  (frame (place-node (frame-root f) reg)))

(define (place-node n a)
  (cond
    [(not n) #f]
    [(leaf? n)
     (define v (leaf-view n))
     (leaf (view-set-rect v (area-x a) (area-y a) (area-w a) (area-h a)))]
    [else
     (define dir (split-dir n))
     (define total (if (eq? dir 'lr) (area-w a) (area-h a)))
     (define size (max 1 (or (split-size n) (quotient (- total gap) 2))))
     (define-values (a* b) (area-split a dir size))
     (define b* (if (eq? dir 'lr)
                    (area (+ (area-x b) gap) (area-y b) (max 1 (- (area-w b) gap)) (area-h b))
                    (area (area-x b) (+ (area-y b) gap) (area-w b) (max 1 (- (area-h b) gap)))))
     (struct-copy split n
                  [a (place-node (split-a n) a*)]
                  [b (place-node (split-b n) b*)])]))

;;; ---------- 结构操作（纯） ----------

;; 把 vid 的叶换成一个 split(dir, leaf vid, leaf new-view)——外层分屏。
(define (frame-split f vid dir new-view [size #f])
  (define (go n)
    (cond
      [(not n) (leaf new-view)]
      [(leaf? n) (if (eqv? vid (view-id (leaf-view n)))
                     (split dir size n (leaf new-view))
                     n)]
      [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 删掉 vid 的叶；空 → #f。
(define (frame-remove f vid)
  (define (go n)
    (cond
      [(not n) #f]
      [(leaf? n) (if (eqv? vid (view-id (leaf-view n))) #f n)]
      [else
       (define a (go (split-a n)))
       (define b (go (split-b n)))
       (cond [(and a b) (struct-copy split n [a a] [b b])]
             [a a] [b b] [else #f])]))
  (frame (go (frame-root f))))

;; 把 vid 的叶整体替换成 new-root（叶或 split）。
(define (frame-replace f vid new-root)
  (define (go n)
    (cond
      [(not n) #f]
      [(leaf? n) (if (eqv? vid (view-id (leaf-view n))) new-root n)]
      [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 交换两个 vid 所在的 view（位置不变）。
(define (frame-swap f v1 v2)
  (define views (frame-views f))
  (define vv1 (for/first ([v (in-list views)] #:when (eqv? v1 (view-id v))) v))
  (define vv2 (for/first ([v (in-list views)] #:when (eqv? v2 (view-id v))) v))
  (cond
    [(or (not vv1) (not vv2)) f]
    [else
     (define (go n)
       (cond
         [(not n) #f]
         [(leaf? n)
          (define id (view-id (leaf-view n)))
          (cond [(eqv? id v1) (leaf vv2)]
                [(eqv? id v2) (leaf vv1)]
                [else n])]
         [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
     (frame (go (frame-root f)))]))

;; 沿 vid 所在路径找最近的同向 split，把第一段尺寸调 delta。axis : 'width | 'height。
(define (node-contains? n vid)
  (cond [(not n) #f]
        [(leaf? n) (eqv? vid (view-id (leaf-view n)))]
        [else (or (node-contains? (split-a n) vid) (node-contains? (split-b n) vid))]))

(define (frame-resize f vid axis delta reg)
  (define target (if (eq? axis 'width) 'lr 'tb))
  (define (go node a)
    (cond
      [(not node) #f]
      [(leaf? node) node]
      [else
       (define dir (split-dir node))
       (define e (max 2 (if (eq? dir 'lr) (area-w a) (area-h a))))
       (define s (max 1 (or (split-size node) (quotient e 2))))
       (define in-a? (node-contains? (split-a node) vid))
       (define in-b? (node-contains? (split-b node) vid))
       (cond
         [(and (eq? dir target) (or in-a? in-b?))
          (struct-copy split node
                       [size (max 1 (min (- e 2) (+ s (if in-a? delta (- delta)))))])]
         [else
          (define-values (a* b*) (area-split a dir s))
          (struct-copy split node
                       [a (if in-a? (go (split-a node) a*) (split-a node))]
                       [b (if in-b? (go (split-b node) b*) (split-b node))])])]))
  (frame (go (frame-root f) reg)))

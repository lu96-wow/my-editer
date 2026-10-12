#lang racket

;;; edit4/layout/geometry.rkt —— 树 × 区域 → 矩形 + cuts（纯投影）
;;;
;;;   placement : id -> rect
;;;   cut       = (axis offset segs)   axis = 'x（竖线，常数 x）| 'y（横线，常数 y）
;;;   seg       = 同一条线上的一段缝：带拖拽所需的快照（该 split 的 lens/mins + 段序号）
;;;
;;; 关键：**按坐标把缝段聚成一条 cut**。同一 x 的所有竖缝 = 一条线；同一 y 的横缝 = 一条线。
;;; 于是普通缝 / 十字 / T 字 / 整条线在命中与拖拽里是同一种东西。

(provide (struct-out seg) (struct-out cut) (struct-out geometry)
         layout neighbor)

(require "rect.rkt" "size.rkt" "tree.rkt" racket/list)

(struct seg (path index lens mins span-lo span-hi) #:transparent)
(struct cut (axis offset segs) #:transparent)
(struct geometry (rects cuts w h) #:transparent)   ; rects : hash id -> rect

;; 水平 split（左右并排）产生的缝是竖线（'x）；垂直 split 产生横线（'y）。
(define (split-cut-axis axis) (if (eq? axis 'h) 'x 'y))

(define (layout node area)
  (define rects (make-hash))
  (define acc (make-hash))          ; (axis . offset) -> (listof seg)，逆序累积
  (define (add-seg axis offset s)
    (hash-update! acc (cons axis offset) (lambda (l) (cons s l)) '()))

  (define (walk n r path)
    (cond
      [(not n) (void)]
      [(leaf? n) (hash-set! rects (leaf-id n) r)]
      [else
       (define axis (split-axis n))
       (define gut (split-gutter n))
       (define kids (split-kids n))
       (define k (length kids))
       (define sizes (map child-size kids))
       (define mins (map (lambda (c) (axis-min (child-node c) axis)) kids))
       (define extent (if (eq? axis 'h) (rect-w r) (rect-h r)))
       (define lens (solve-axis extent gut sizes mins))
       (define x0 (rect-x r))
       (define y0 (rect-y r))
       (define off 0)
       (for ([c (in-list kids)] [len (in-list lens)] [i (in-naturals)])
         (define cr (if (eq? axis 'h)
                        (rect (+ x0 off) y0 len (rect-h r))
                        (rect x0 (+ y0 off) (rect-w r) len)))
         (walk (child-node c) cr (append path (list i)))
         (set! off (+ off len))
         (when (< i (sub1 k))
           (define pos (+ (if (eq? axis 'h) x0 y0) off))
           (define span-lo (if (eq? axis 'h) y0 x0))
           (define span-hi (+ span-lo (if (eq? axis 'h) (rect-h r) (rect-w r))))
           (add-seg (split-cut-axis axis) pos (seg path i lens mins span-lo span-hi))
           (set! off (+ off gut))))]))

  (walk node area '())
  (define cuts
    (sort (for/list ([(key segs) (in-hash acc)])
            (cut (car key) (cdr key) (reverse segs)))
          (lambda (a b)
            (cond
              [(and (eq? 'x (cut-axis a)) (eq? 'y (cut-axis b))) #t]
              [(and (eq? 'y (cut-axis a)) (eq? 'x (cut-axis b))) #f]
              [else (< (cut-offset a) (cut-offset b))]))))
  (geometry rects cuts (rect-w area) (rect-h area)))

;;; ---------- 方向导航 ----------

;; neighbor : geometry id dir -> id | #f   （dir = 'left|'right|'up|'down）
;; 在给定方向上、与源矩形在垂直轴上有重叠的窗里，取最近的。
(define (neighbor g id dir)
  (define r (hash-ref (geometry-rects g) id #f))
  (cond
    [(not r) #f]
    [else
     (define cands
       (for/list ([(id2 r2) (in-hash (geometry-rects g))]
                  #:when (and (not (eqv? id id2))
                              (in-direction? dir r r2)
                              (overlap? dir r r2)))
         (cons id2 r2)))
     (define ordered
       (sort cands (lambda (a b) (better? dir r a b))))
     (and (pair? ordered) (car (car ordered)))]))

(define (in-direction? dir r r2)
  (case dir
    [(left)  (<= (rect-right r2) (rect-x r))]
    [(right) (>= (rect-x r2) (rect-right r))]
    [(up)    (<= (rect-bottom r2) (rect-y r))]
    [(down)  (>= (rect-y r2) (rect-bottom r))]
    [else #f]))

;; 垂直轴上是否重叠（半开区间）
(define (overlap? dir r r2)
  (case dir
    [(left right) (< (max (rect-y r) (rect-y r2)) (min (rect-bottom r) (rect-bottom r2)))]
    [(up down)    (< (max (rect-x r) (rect-x r2)) (min (rect-right r) (rect-right r2)))]
    [else #f]))

(define big (expt 10 12))

;; 沿轴间隔
(define (dist dir r r2)
  (case dir
    [(left)  (- (rect-x r) (rect-right r2))]
    [(right) (- (rect-x r2) (rect-right r))]
    [(up)    (- (rect-y r) (rect-bottom r2))]
    [(down)  (- (rect-y r2) (rect-bottom r))]
    [else big]))

(define (overlap-len dir r r2)
  (case dir
    [(left right) (- (min (rect-bottom r) (rect-bottom r2)) (max (rect-y r) (rect-y r2)))]
    [(up down)    (- (min (rect-right r) (rect-right r2)) (max (rect-x r) (rect-x r2)))]
    [else 0]))

(define (center-dist dir r r2)
  (case dir
    [(left right) (abs (- (+ (rect-y r) (quotient (rect-h r) 2))
                          (+ (rect-y r2) (quotient (rect-h r2) 2))))]
    [(up down)    (abs (- (+ (rect-x r) (quotient (rect-w r) 2))
                          (+ (rect-x r2) (quotient (rect-w r2) 2))))]
    [else big]))

;; 排序：先距离、再重叠大、再中心近、最后 id 字符串（确定性）
(define (better? dir r a b)
  (define da (dist dir r (cdr a)))
  (define db (dist dir r (cdr b)))
  (cond
    [(< da db) #t] [(> da db) #f]
    [else
     (define oa (overlap-len dir r (cdr a)))
     (define ob (overlap-len dir r (cdr b)))
     (cond
       [(> oa ob) #t] [(< oa ob) #f]
       [else
        (define ca (center-dist dir r (cdr a)))
        (define cb (center-dist dir r (cdr b)))
        (cond
          [(< ca cb) #t] [(> ca cb) #f]
          [else (string<? (format "~a" (car a)) (format "~a" (car b)))])])]))

#lang racket

;;; edit4/layout/hit.rkt —— 命中 + 拖拽（纯）
;;;
;;;   hit      : geometry x y -> (or/c id (listof cut) #f)
;;;              点在内容 → id；点在缝/交点 → 落在其上的 cut（1 或 2 条）
;;;   move-cut : (listof seg) delta -> (listof (list path index bi bj))
;;;              对同一次拖拽涉及的所有缝段取**可移动区间的交集**，再统一施加；
;;;              于是整条线不会有一段被 min 卡住、另一段跑出去。
;;;
;;; 交点判定：一条竖 cut 与一条横 cut 在「点处相邻」即构成十字 / T。
;;; 无需特殊数据结构——cut 本身就是线，交点只是同时命中两条线。

(provide hit cut-contains?
         seg-lo seg-hi move-cut segs-of-axis)

(require "rect.rkt" "geometry.rkt" "tree.rkt" racket/list)

(define (cut-contains? c x y)
  (cond
    [(eq? 'x (cut-axis c))
     (and (= x (cut-offset c))
          (for/or ([s (in-list (cut-segs c))])
            (and (<= (seg-span-lo s) y) (< y (seg-span-hi s)))))]
    [(eq? 'y (cut-axis c))
     (and (= y (cut-offset c))
          (for/or ([s (in-list (cut-segs c))])
            (and (<= (seg-span-lo s) x) (< x (seg-span-hi s)))))]
    [else #f]))

;; 该 cut 是否「够到」某坐标（用于交点：横线止于此竖线，或起于其右侧）
(define (cut-reaches? c coord)
  (for/or ([s (in-list (cut-segs c))])
    (or (= (seg-span-hi s) coord) (= (seg-span-lo s) (add1 coord)))))

(define (hit g x y)
  (define cs (geometry-cuts g))
  (define xs (for/list ([c (in-list cs)]
                        #:when (and (eq? 'x (cut-axis c)) (cut-contains? c x y)))
               c))
  (define ys (for/list ([c (in-list cs)]
                        #:when (and (eq? 'y (cut-axis c)) (cut-contains? c x y)))
               c))
  (define extra-y (if (pair? xs)
                      (for/list ([c (in-list cs)]
                                 #:when (and (eq? 'y (cut-axis c)) (= y (cut-offset c))
                                             (cut-reaches? c x)))
                        c)
                      '()))
  (define extra-x (if (pair? ys)
                      (for/list ([c (in-list cs)]
                                 #:when (and (eq? 'x (cut-axis c)) (= x (cut-offset c))
                                             (cut-reaches? c y)))
                        c)
                      '()))
  (define hits (remove-duplicates (append xs ys extra-y extra-x)))
  (cond
    [(pair? hits) hits]
    [else
     (for/first ([(id r) (in-hash (geometry-rects g))]
                 #:when (rect-contains? r x y))
       id)]))

;;; ---------- 拖拽 ----------

;; 段允许的 delta 区间（不含端点越界）：[-(len_i-min_i), +(len_j-min_j)]
(define (seg-lo s)
  (define i (seg-index s))
  (- (list-ref (seg-mins s) i) (list-ref (seg-lens s) i)))
(define (seg-hi s)
  (define i (seg-index s))
  (- (list-ref (seg-lens s) (add1 i)) (list-ref (seg-mins s) (add1 i))))

;; 取某轴的 cut 的全部缝段（一次拖拽可能同时动两条线）。
(define (segs-of-axis hits axis)
  (append* (for/list ([c (in-list hits)] #:when (eq? axis (cut-axis c)))
             (cut-segs c))))

;; move-cut : (listof seg) delta -> (listof (list path sizes))
;;   对所有段取可移动区间的交集（min 约束），再统一施加。
;;   每条 move 回写**整个 split** 的 sizes（保持 Σsizes = content）→ 其它项不动。
(define (move-cut segs delta)
  (cond
    [(null? segs) '()]
    [else
     (define lo (apply max (for/list ([s (in-list segs)]) (seg-lo s))))
     (define hi (apply min (for/list ([s (in-list segs)]) (seg-hi s))))
     (define d (max lo (min hi delta)))
     (for/list ([s (in-list segs)])
       (define i (seg-index s))
       (define sizes (for/list ([l (in-list (seg-lens s))] [j (in-naturals)])
                       (cond [(= j i) (+ l d)]
                             [(= j (add1 i)) (- l d)]
                             [else l])))
       (list (seg-path s) sizes))]))

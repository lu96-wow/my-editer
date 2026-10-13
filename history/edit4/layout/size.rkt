#lang racket

;;; edit4/layout/size.rkt —— 尺寸意图 + 1-D 求解器（轴无关）
;;;
;;; 这是布局里唯一的「难数学」。它不认识树、不认识矩形、不认识 id。
;;;
;;;   size = (basis elastic?)
;;;     basis    : 当前的期望格数（一般 = 上次解出的长度，恒 >= min）
;;;     elastic? : #t = 弹性（容器 resize 时按当前尺寸等比缩放）；#f = 固定
;;;
;;;   solve-axis : extent gutter sizes mins [actives] -> (listof 长度)
;;;     actives 缺省全 #t；#f 的项是折叠 dock：长度恒 0、不占缝、不参与增/减（返回等长）。
;;;
;;; 规则（DESIGN）：
;;;   1. content = max 0 (extent - (k-1)*gutter)    （k = 活动项数）
;;;   2. content <= Σmin         → 返回 min（硬下限；溢出也不压塌）
;;;   3. content == Σbasis       → 直接返回 basis（**精确快路径**：其它项完全不动）
;;;   4. 否则把差额**按当前尺寸等比分配/收回**（固定项不参与）→ **比例永不漂**
;;;        （权重取弹性项的 basis；收回时以 min 为底；最大余数法，无抖动）
;;;
;;; 因为 basis 恒 >= min（新 split 以当前长度/最小值初始化；拖拽只改两个 basis 且
;;; 由 min 夹住），求解器不需要「抬到 min 再削回」的补丁。

(provide (struct-out size) solve-axis)

(require racket/list)

(struct size (basis elastic?) #:transparent)
;; basis    : exact-nonnegative-integer
;; elastic? : boolean

;; 用作「无上限」的哨兵：远大于任何屏幕尺寸，且保持精确整数。
(define big-cap (expt 10 12))

;;; ---------- 按权重分配（带上限的蓄水/最大余数） ----------

;; distribute : amount weights caps -> (listof allocated)
;;   0 <= allocated[i] <= caps[i]；Σallocated = min(amount, Σcaps)。
;;   weights 全 0 时均分；用精确有理数比较，最后最大余数落整。确定、无抖动。
(define (distribute amount weights caps)
  (define n (length weights))
  (define alloc (make-vector n 0))
  (define (room i) (- (list-ref caps i) (vector-ref alloc i)))
  (let loop ([remaining amount] [active (range n)])
    (cond
      [(or (<= remaining 0) (null? active)) (vector->list alloc)]
      [else
       (define tw (for/sum ([i (in-list active)]) (list-ref weights i)))
       (define (share i)
         (if (zero? tw)
             (/ remaining (length active))
             (/ (* remaining (list-ref weights i)) tw)))
       (define over (for/list ([i (in-list active)] #:when (> (share i) (room i))) i))
       (cond
         [(pair? over)
          (for ([i (in-list over)]) (vector-set! alloc i (list-ref caps i)))
          (loop (- remaining (for/sum ([i (in-list over)]) (room i)))
                (filter-not (lambda (i) (memv i over)) active))]
         [else
          (define fl (for/list ([i (in-list active)]) (floor (share i))))
          (define used (for/sum ([f (in-list fl)]) f))
          (define leftover (- remaining used))
          (for ([i (in-list active)] [f (in-list fl)])
            (vector-set! alloc i (+ (vector-ref alloc i) f)))
          (define order
            (sort (for/list ([i (in-list active)] [f (in-list fl)])
                    (cons i (- (share i) f)))
                  (lambda (a b) (or (> (cdr a) (cdr b))
                                    (and (= (cdr a) (cdr b)) (< (car a) (car b)))))))
          (for ([ir (in-list order)] [k (in-naturals)] #:break (>= k leftover))
            (vector-set! alloc (car ir) (add1 (vector-ref alloc (car ir)))))
          (vector->list alloc)])])))

;;; ---------- 求解 ----------

;; solve-axis : extent gutter sizes mins [actives] -> (listof 长度)
;;   actives 缺省全 #t；#f 的项视为折叠：长度恒 0，不占缝、不参与增/减。
;;   返回与 sizes 等长（折叠位置为 0），保持 idx 对齐。
(define (solve-axis extent gutter sizes mins [actives #f])
  (define act (or actives (make-list (length sizes) #t)))
  (define idxs (for/list ([a (in-list act)] [i (in-naturals)] #:when a) i))
  (cond
    [(null? idxs) (make-list (length sizes) 0)]
    [else
     (define as (map (lambda (i) (list-ref sizes i)) idxs))
     (define am (map (lambda (i) (list-ref mins i)) idxs))
     (define lens (solve-active extent gutter as am))
     (define out (make-vector (length sizes) 0))
     (for ([i (in-list idxs)] [l (in-list lens)]) (vector-set! out i l))
     (vector->list out)]))

(define (solve-active extent gutter sizes mins)
  (define k (length sizes))
  (cond
    [(zero? k) '()]
    [else
     (define content (max 0 (- extent (* (sub1 k) gutter))))
     (define min-sum (for/sum ([m (in-list mins)]) m))
     (cond
       [(<= content min-sum) mins]                       ; 3. 硬下限
       [else
        (define bases (map size-basis sizes))
        (define basis-sum (for/sum ([b (in-list bases)]) b))
        ;; 弹性项参与**等比缩放**：权重 = 当前尺寸。固定项权重 0。
        (define weights (for/list ([s (in-list sizes)] [b (in-list bases)])
                          (if (size-elastic? s) b 0)))
        (cond
          [(= content basis-sum) bases]                  ; 4. 精确快路径
          [(> content basis-sum)
           (define extra (distribute (- content basis-sum) weights (make-list k big-cap)))
           (for/list ([b (in-list bases)] [e (in-list extra)]) (+ b e))]
          [else
           (define deficit (- basis-sum content))
           ;; 第一轮：弹性项按比例收回，下限 min。
           (define caps1 (for/list ([b (in-list bases)] [m (in-list mins)]) (- b m)))
           (define cut1 (distribute deficit weights caps1))
           (define rem1 (- deficit (for/sum ([c (in-list cut1)]) c)))
           (cond
             [(zero? rem1)
              (for/list ([b (in-list bases)] [c (in-list cut1)]) (- b c))]
             ;; 第二轮：固定项也均摊（仍以 min 为底）。
             [else
              (define caps2 (for/list ([b (in-list bases)] [m (in-list mins)] [c (in-list cut1)])
                              (- (- b m) c)))
              (define cut2 (distribute rem1 (make-list k 1) caps2))
              (for/list ([b (in-list bases)] [c1 (in-list cut1)] [c2 (in-list cut2)])
                (- b c1 c2))])])])]))

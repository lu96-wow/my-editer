#lang racket

;;; projection/geometry.rkt —— region 布局树 → 屏幕几何（纯）
;;;
;;;   geometry-solve : layout area -> (values (listof region-panel) (listof cut))
;;;
;;; region-panel = 一块区域在屏幕上的外框 + 有效边框 + 内容区。
;;; cut          = 相邻区域共享的 1 格接缝（后续鼠标拖缝用）。
;;;
;;; 分配规则（与旧 layout/solve 一致）：
;;;   · fixed 先取（内容格 + 沿轴边框厚度）；
;;;   · 剩余按权重分给 flex，钳制 min/max（内容格）；
;;;   · 没有 flex 时余量给第一个孩子（末尾/右侧固定区域贴边）。
;;;   · 相邻兄弟共享 1 格接缝；总格数 = ext + (n-1)。
;;;
;;; area 用 core 的 rect（x=列 y=行）；本模块只依赖 core 的 rect，不依赖 view / buffer。

(provide (struct-out region-panel)
         (struct-out cut)
         geometry-solve
         region-panel-map
         region-panel-at
         cut-at cuts-at
         tree-resize-seam
         leaf-effective-borders
         axis-thickness)

(require "../model/layout.rkt"
         "../../core/view/base/rect.rkt")

;;; ════════════════ 结果类型 ════════════════

(struct region-panel (region rect borders content) #:transparent)
;; region  : region-id
;; rect    : 外框（屏幕坐标）
;; borders : (listof 'up 'down 'left 'right) 实际存在的边
;; content : 内容区 rect（外框按存在的边内缩）

(struct cut (axis offset span-lo span-hi path index cells-before cells-after) #:transparent)
;; axis        'lr（竖缝，offset=列）| 'tb（横缝，offset=行）
;; span-lo/hi  缝的纵向 / 横向范围 [lo, hi)
;; path        到所属 split 的孩子下标路径
;; index       缝左 / 上方的可见孩子下标
;; cells-before/after 两侧当前 rect 格数

;;; ════════════════ 边框 ════════════════

;; 叶子有效边框 = 内部边 ∪ (外部边 ∩ 它声明的 borders)。
(define (leaf-effective-borders l outer)
  (for/list ([e (in-list leaf-borders-all)]
             #:when (or (not (memq e outer)) (memq e (leaf-borders l))))
    e))

;; 沿轴边框厚度（fixed/min/max 是内容格，转 rect 时加它）。
(define (axis-thickness n outer axis)
  (cond
    [(split? n) 0]
    [else
     (define bs (leaf-effective-borders n outer))
     (for/sum ([e (in-list (if (eq? axis 'lr) '(left right) '(up down)))]
               #:when (memq e bs))
       1)]))

;;; ════════════════ 分配 ════════════════

(define (int-alloc raw extent)
  (define n (length raw))
  (cond
    [(zero? n) '()]
    [else
     (define base (map (λ (x) (inexact->exact (floor x))) raw))
     (define used (apply + base))
     (define need (- extent used))
     (define order (sort (for/list ([x raw] [i (in-naturals)])
                           (cons (- x (floor x)) i))
                         > #:key car))
     (define add (make-vector n 0))
     (for ([p (in-list (take order (max 0 (min need n))))])
       (vector-set! add (cdr p) 1))
     (for/list ([b base] [i (in-naturals)]) (+ b (vector-ref add i)))]))

(define (clamp c lo hi)
  (define x (max 0 c))
  (cond [(and lo (< x lo)) lo]
        [(and hi (> x hi)) hi]
        [else x]))

(define (scale-to sizes total)
  (define s (apply + sizes))
  (cond [(zero? s) (make-list (length sizes) 0)]
        [else (int-alloc (map (λ (x) (* total (/ x s))) sizes) total)]))

;; flex 分配：rem 个 rect 格按权重分，钳制 [min,max]（内容 -> rect 加 thick）。
(define (alloc-flex dims thicks idxs rem)
  (define n (length idxs))
  (cond
    [(zero? n) '()]
    [else
     (define (d i) (list-ref dims i))
     (define (th i) (list-ref thicks i))
     (define weights (for/list ([i idxs]) (dim-value (d i))))
     (define los (for/list ([i idxs]) (and (dim-lo (d i)) (+ (dim-lo (d i)) (th i)))))
     (define his (for/list ([i idxs]) (and (dim-hi (d i)) (+ (dim-hi (d i)) (th i)))))
     (define los* (if (<= (for/sum ([x los]) (or x 0)) rem) los (make-list n #f)))
     (define result (make-vector n #f))
     (let loop ([rem rem] [free (range n)])
       (cond
         [(null? free)
          (when (and (positive? rem) (positive? n))
            (vector-set! result 0 (+ (vector-ref result 0) rem)))
          (for/list ([i (in-range n)]) (vector-ref result i))]
         [else
          (define ws (for/list ([i free]) (list-ref weights i)))
          (define total (apply + ws))
          (define raw (if (zero? total)
                          (for/list ([i free]) (/ rem (length free)))
                          (for/list ([i free] [w ws]) (* rem (/ w total)))))
          (define cells (int-alloc raw rem))
          (define clamped (for/list ([i free] [c cells])
                            (list i c (clamp c (list-ref los* i) (list-ref his i)))))
          (define newly (for/list ([p clamped] #:when (not (= (cadr p) (caddr p)))) p))
          (cond
            [(null? newly)
             (for ([i free] [c cells]) (vector-set! result i c))
             (for/list ([i (in-range n)]) (vector-ref result i))]
            [else
             (for ([p newly]) (vector-set! result (car p) (caddr p)))
             (loop (- rem (for/sum ([p newly]) (caddr p)))
                   (for/list ([i free] #:unless (assq i newly)) i))])]))]))

;; 把 budget 分给孩子们，返回每个孩子的 rect 格数。
(define (alloc-dims dims thicks budget)
  (define n (length dims))
  (cond
    [(zero? n) '()]
    [else
     (define B (max 0 budget))
     (define fixed-rects
       (for/list ([d dims] [t thicks])
         (and (dim-fixed? d) (max 0 (+ (dim-value d) t)))))
     (define fsum (for/sum ([x fixed-rects]) (or x 0)))
     (define fixed*
       (if (<= fsum B)
           fixed-rects
           (scale-to (map (λ (x) (or x 0)) fixed-rects) B)))
     (define used (for/sum ([x fixed*]) (or x 0)))
     (define rem (max 0 (- B used)))
     (define flex-idx (for/list ([d dims] [i (in-naturals)] #:when (dim-flex? d)) i))
     (cond
       [(null? flex-idx)
        (define base (map (λ (x) (or x 0)) fixed*))
        (list-set base 0 (+ (list-ref base 0) (max 0 (- B (apply + base)))))]
       [else
        (define fr (alloc-flex dims thicks flex-idx rem))
        (for/list ([i (in-range n)])
          (if (memv i flex-idx)
              (list-ref fr (index-of flex-idx i))
              (or (list-ref fixed* i) 0)))])]))

;;; ════════════════ 遍历 ════════════════

(define (rect-content r borders)
  (rect-inset-sides r
                    (if (memq 'up borders) 1 0)
                    (if (memq 'right borders) 1 0)
                    (if (memq 'down borders) 1 0)
                    (if (memq 'left borders) 1 0)))

(define (solve tree area)
  (define panels '())
  (define cuts '())
  (define (walk n r outer path)
    (cond
      [(leaf? n)
       (when (leaf-visible? n)
         (define bs (leaf-effective-borders n outer))
         (set! panels (cons (region-panel (leaf-region n) r bs (rect-content r bs))
                            panels)))]
      [else
       (define axis (split-axis n))
       (define vis (for/list ([c (in-list (split-children n))] [i (in-naturals)]
                              #:when (node-visible? c))
                     (cons i c)))
       (define nvis (length vis))
       (define ext (if (eq? axis 'lr) (rect-w r) (rect-h r)))
       (define total (+ ext (max 0 (sub1 nvis))))
       (define last (sub1 nvis))
       (define infos
         (for/list ([vx (in-list vis)] [idx (in-naturals)])
           (define i (car vx)) (define c (cdr vx))
           (define child-outer
             (let ([o (if (< idx last) (remove (if (eq? axis 'lr) 'right 'down) outer)
                          outer)])
               (if (zero? idx) o (remove (if (eq? axis 'lr) 'left 'up) o))))
           (list i c child-outer (axis-thickness c child-outer axis))))
       (define sizes (alloc-dims (for/list ([info infos]) (node-dim (cadr info)))
                                 (for/list ([info infos]) (cadddr info))
                                 total))
       (define off (if (eq? axis 'lr) (rect-x r) (rect-y r)))
       (define lo  (if (eq? axis 'lr) (rect-y r) (rect-x r)))
       (define hi  (if (eq? axis 'lr) (rect-bottom r) (rect-right r)))
       (define prev-i #f)
       (define prev-sz #f)
       (for ([info (in-list infos)] [sz (in-list sizes)])
         (define i (car info)) (define c (cadr info)) (define child-outer (caddr info))
         (when prev-i
           (set! cuts (cons (cut axis off lo hi path prev-i prev-sz sz) cuts)))
         (walk c (if (eq? axis 'lr)
                     (rect off (rect-y r) sz (rect-h r))
                     (rect (rect-x r) off (rect-w r) sz))
               child-outer
               (append path (list i)))
         (set! off (+ off (max 0 (sub1 sz))))
         (set! prev-i i)
         (set! prev-sz sz))]))
  (walk tree area leaf-borders-all '())
  (values (reverse panels) (reverse cuts)))

(define (geometry-solve tree area) (solve tree area))

(define (region-panel-map panels)
  (for/hash ([p (in-list panels)]) (values (region-panel-region p) p)))

(define (region-panel-at panels row col)
  (for/first ([p (in-list panels)]
              #:when (rect-contains? (region-panel-rect p) col row))
    p))

;;; ════════════════ 接缝 ════════════════

(define (cut-match? c row col)
  (case (cut-axis c)
    [(lr) (and (= col (cut-offset c))
               (<= (cut-span-lo c) row) (< row (cut-span-hi c)))]
    [(tb) (and (= row (cut-offset c))
               (<= (cut-span-lo c) col) (< col (cut-span-hi c)))]))

(define (cuts-at cuts row col)
  (for/list ([c (in-list cuts)] #:when (cut-match? c row col)) c))

(define (cut-at cuts row col)
  (for/or ([c (in-list cuts)] #:when (cut-match? c row col)) c))

;;; ════════════════ 拖缝（按格数 → 新 dim） ════════════════

(define (node-at-path t path)
  (for/fold ([n t]) ([i (in-list path)]) (list-ref (split-children n) i)))

(define (next-visible-index cs i)
  (for/first ([j (in-range (add1 i) (length cs))]
              #:when (node-visible? (list-ref cs j)))
    j))

;; tree-resize-at：path 到 split；i = 缝左/上方可见孩子原始下标。
(define (tree-resize-at t path i d-i d-i+1)
  (define di (->dim d-i)) (define dj (->dim d-i+1))
  (define (go n path)
    (define cs (split-children n))
    (cond
      [(null? path)
       (define j (next-visible-index cs i))
       (if j
           (struct-copy split n
                        [children (list-set (list-set cs i (node-with-dim (list-ref cs i) di))
                                            j (node-with-dim (list-ref cs j) dj))])
           n)]
      [else
       (define k (car path))
       (struct-copy split n [children (list-set cs k (go (list-ref cs k) (cdr path)))])]))
  (go t path))

(define (resize-dims di dj ci cj delta)
  (cond
    [(and (dim-flex? di) (dim-flex? dj))
     (define w (+ (dim-value di) (dim-value dj)))
     (define tot (max 1 (+ ci cj)))
     (define eps (/ w 1000))
     (define ni (max eps (min (- w eps) (* w (/ ci tot)))))
     (list (flex ni #:min (dim-lo di) #:max (dim-hi di))
           (flex (- w ni) #:min (dim-lo dj) #:max (dim-hi dj)))]
    [(and (dim-fixed? di) (dim-fixed? dj))
     (list (fixed (max 0 (+ (dim-value di) delta)))
           (fixed (max 0 (- (dim-value dj) delta))))]
    [(dim-fixed? di)
     (list (fixed (max 0 (+ (dim-value di) delta))) dj)]
    [else
     (list di (fixed (max 0 (- (dim-value dj) delta))))]))

(define (tree-resize-seam tree cut delta)
  (define cs (split-children (node-at-path tree (cut-path cut))))
  (define i (cut-index cut))
  (define j (for/first ([k (in-range (add1 i) (length cs))]
                        #:when (node-visible? (list-ref cs k)))
              k))
  (cond
    [(not j) tree]
    [else
     (define di (node-dim (list-ref cs i)))
     (define dj (node-dim (list-ref cs j)))
     (define ci (max 0 (+ (cut-cells-before cut) delta)))
     (define cj (max 0 (- (cut-cells-after cut) delta)))
     (define ds (resize-dims di dj ci cj delta))
     (tree-resize-at tree (cut-path cut) i (car ds) (cadr ds))]))

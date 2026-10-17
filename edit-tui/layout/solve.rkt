#lang racket

;;; layout/solve.rkt —— 树 → 摆放（纯）
;;;
;;;   tree->panels     : tree area → (listof panel)        core 直接吃
;;;   tree->placements : tree area → (listof (list id rect))
;;;   tree->cuts       : tree area → (listof cut)          缝（拖拽用）
;;;
;;; 同层分配（见 alloc-dims）：
;;;   · fixed 先取固定格数（内容格 + 沿轴边框厚度）；
;;;   · 剩余按权重分给 flex，钳制 min/max（内容格）；
;;;   · 没有 flex 时余量给第一个孩子（让末尾/右侧固定面板贴边）。
;;; 隐藏跳过（dim 保留）。相邻面板**边界重叠**：相邻兄弟共享 1 格接缝
;;; （总格数 = ext + (n-1)），两侧各画自己的边 → 同一格由 border-owner 选 face。
;;; 屏幕边（outer）的框由 leaf 自己声明的 borders 决定去不去。
;;;
;;; area 是外层 rect（屏幕坐标，x=列 y=行）。

(provide (struct-out cut)
         cut-at cuts-at
         tree-resize-seam
         tree->panels tree->placements tree->cuts
         tree->panel-map
         tree-solve)

(require "tree.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt")

(struct cut (axis offset span-lo span-hi path index cells-before cells-after) #:transparent)
;; axis      'lr（竖缝，offset = 列）| 'tb（横缝，offset = 行）
;; span-lo/hi 缝的纵向 / 横向范围 [lo, hi)
;; path      到所属 split 的「孩子下标」路径；index = 缝左 / 上方的可见孩子下标
;; cells-before/after 缝两侧可见孩子当前的 **rect 格数**
;; 拖缝：用 tree-resize-seam 把格数增量换成新的 dim（见文件末）。

;; 屏幕格 (row, col) 命中哪条缝（缝是 1 格宽/高的线）。
(define (cut-match? c row col)
  (case (cut-axis c)
    [(lr) (and (= col (cut-offset c))
               (<= (cut-span-lo c) row) (< row (cut-span-hi c)))]
    [(tb) (and (= row (cut-offset c))
               (<= (cut-span-lo c) col) (< col (cut-span-hi c)))]))
;; 该点命中的所有缝（交点 = 竖缝 + 横缝 → 角拖）。
(define (cuts-at cuts row col)
  (for/list ([c (in-list cuts)] #:when (cut-match? c row col)) c))
;; 第一条（命中优先级由 cuts 顺序决定）。
(define (cut-at cuts row col)
  (for/or ([c (in-list cuts)] #:when (cut-match? c row col)) c))

;;; ---------- 分额度 ----------

;; 整数分配：raw 之和 = extent，返回整数且和为 extent（最大余数）。
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

;; flex 分配：把 rem 个 **rect** 格按权重分给 flex 孩子，钳制 [min,max]（内容 → rect 加 thick）。
;; dims/thicks 与所有孩子对齐；idxs = flex 孩子的位置。
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
     ;; min 不可行 → 忽略 min
     (define los* (if (<= (for/sum ([x los]) (or x 0)) rem) los (make-list n #f)))
     (define result (make-vector n #f))
     (let loop ([rem rem] [free (range n)])
       (cond
         [(null? free)
          ;; 都顶到 max 还有余 → 给第一个 flex（宁可超 max 也填满）
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

;; 把 budget 分给孩子们，返回每个孩子的 **rect 格数**。
;; dims/thicks 等长；fixed 取 (value + thick)，flex 分余量。
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
       ;; 没有 flex：余量给第一个孩子（让末尾固定面板贴底/贴右）
       [(null? flex-idx)
        (define base (map (λ (x) (or x 0)) fixed*))
        (list-set base 0 (+ (list-ref base 0) (max 0 (- B (apply + base)))))]
       [else
        (define fr (alloc-flex dims thicks flex-idx rem))
        (for/list ([i (in-range n)])
          (if (memv i flex-idx)
              (list-ref fr (index-of flex-idx i))
              (or (list-ref fixed* i) 0)))])]))

;;; ---------- 遍历 ----------

;; 叶子有效边框 = 内部边 ∪ (外部边 ∩ 它声明的 borders)。
(define (leaf-effective-borders n outer)
  (for/list ([e (in-list '(up down left right))]
             #:when (or (not (memq e outer)) (memq e (leaf-borders n))))
    e))

;; 沿轴边框厚度（fixed/min/max 是内容格，转 rect 时加它）。
(define (axis-thickness n outer axis)
  (cond
    [(split? n) 0]
    [else
     (define bs (leaf-effective-borders n outer))
     (for/sum ([e (in-list (if (eq? axis 'lr) '(left right) '(up down)))]
               #:when (memq e bs)) 1)]))

(define (solve tree area)
  (define placements '())
  (define panels '())
  (define cuts '())
  (define (walk n r outer path)
    (cond
      [(leaf? n)
       (when (leaf-visible? n)
         (set! placements (cons (list (leaf-id n) r) placements))
         (set! panels (cons (make-panel (leaf-view n) r (leaf-effective-borders n outer)
                                        #:face (leaf-face n) #:weight (leaf-weight n))
                            panels)))]
      [else
       (define axis (split-axis n))
       (define vis (for/list ([c (in-list (split-children n))] [i (in-naturals)]
                              #:when (node-visible? c))
                     (cons i c)))
       (define nvis (length vis))
       (define ext (if (eq? axis 'lr) (rect-w r) (rect-h r)))
       (define total (+ ext (max 0 (sub1 nvis))))     ; 每条缝共享 1 格
       (define last (sub1 nvis))
       ;; 先算每个可见孩子的 outer + 沿轴边框厚度（只依赖位置，不依赖尺寸）
       (define infos
         (for/list ([vx (in-list vis)] [idx (in-naturals)])
           (define i (car vx)) (define c (cdr vx))
           (define child-outer
             (let ([o (if (< idx last) (remove (if (eq? axis 'lr) 'right 'down) outer) outer)])
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
         (set! off (+ off (max 0 (sub1 sz))))           ; 下一块从本块最后一格开始（共享缝）
         (set! prev-i i)
         (set! prev-sz sz))]))
  (walk tree area '(up down left right) '())
  (values (reverse placements) (reverse panels) (reverse cuts)))

(define (tree->placements tree area)
  (call-with-values (λ () (solve tree area)) (λ (pl pa c) pl)))
(define (tree->panels tree area)
  (call-with-values (λ () (solve tree area)) (λ (pl pa c) pa)))
(define (tree->cuts tree area)
  (call-with-values (λ () (solve tree area)) (λ (pl pa c) c)))

;; 可见 leaf: id → panel（与 tree->panels 同一次 walk，顺序一致）。
(define (tree->panel-map tree area)
  (define-values (pl pa c) (solve tree area))
  (for/hash ([p (in-list pl)] [panel (in-list pa)]) (values (car p) panel)))

;; 一次 solve 拿全部（placements / panels / cuts）—— 热路径（鼠标）用，避免重复解。
(define (tree-solve tree area) (solve tree area))

;;; ---------- 拖缝（按格数 → 新 dim）----------

;; 沿 path 走到 split（path 是孩子下标表）。
(define (node-at-path t path)
  (for/fold ([n t]) ([i (in-list path)]) (list-ref (split-children n) i)))

;; 两个相邻孩子的 dim → 拖后的新 dim。
;; ci/cj 是新的 rect 格数；delta = ci - 旧 ci。
;;   flex+flex : 总权重不变，按新格数比例重分（其它兄弟不受影响）
;;   fixed     : 直接改固定值（content 增量 = rect 增量；不钉住）
;;   fixed+flex: 固定侧改，flex 侧吸收
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

;; 拖缝：delta = 格数增量（lr 用列、tb 用行）。与 tree-resize-at 同一条“下一个可见孩子”规则。
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

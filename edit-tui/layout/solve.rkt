#lang racket

;;; layout/solve.rkt —— 树 → 摆放（纯）
;;;
;;;   tree->panels     : tree area → (listof panel)        core 直接吃
;;;   tree->placements : tree area → (listof (list id rect))
;;;   tree->cuts       : tree area → (listof cut)          缝（拖拽用）
;;;
;;; 同层按 size 权重比例分额度；隐藏跳过（size 保留）。相邻面板**边界重叠**：
;;; 相邻兄弟共享 1 格接缝（总格数 = ext + (n-1)），两侧各画自己的边 →
;;; 重叠在同一格，由 core border-owner（deep/weight/列表序）选一个 face = 一条线。
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
;; cells-before/after 缝两侧可见孩子当前的**格数**（tree 里存的是**权重** size）
;; 拖缝：用 tree-resize-seam 把格数增量换成新的 size（见文件末）。

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

;; 按 sizes 权重把 extent 分成整数格（floor 后把余数按顺序补给前面几块）。
(define (weighted-sizes sizes extent)
  (define n (length sizes))
  (cond
    [(zero? n) '()]
    [else
     (define total (apply + sizes))
     (if (zero? total)
         (let-values ([(q r) (quotient/remainder (max 0 extent) n)])
           (for/list ([i (in-range n)]) (+ q (if (< i r) 1 0))))
         (let* ([base (for/list ([s (in-list sizes)])
                        (inexact->exact (floor (* extent (/ s total)))))]
                [used (apply + base)]
                [rem (- extent used)]
                [extra (for/list ([i (in-range n)]) (if (< i rem) 1 0))])
           (map + base extra)))]))
;; 额度不会小于 0（extent>=0，floor 非负）。

;;; ---------- 遍历 ----------

;; 相邻面板**边界重叠**：相邻兄弟共享 1 格接缝（总格数 = ext + (n-1)）。
;; 接缝两侧都画自己的边 → 重叠在同一格，由 border-owner 选一个 face = 一条线。
;; 屏幕边（outer）的框由 dock 决定去不去。
;;
;; outer 边集随 rect 下推：非最后孩子把「右(lr)/下(tb)」变内部，非第一把「左(lr)/上(tb)」变内部。
;; 叶子有效边框 = 内部边 ∪ (外部边 ∩ 它声明的 borders)。
(define (solve tree area)
  (define placements '())
  (define panels '())
  (define cuts '())
  (define (walk n r outer path)
    (cond
      [(leaf? n)
       (when (leaf-visible? n)
         (define bs (for/list ([e (in-list '(up down left right))]
                               #:when (or (not (memq e outer)) (memq e (leaf-borders n))))
                      e))
         (set! placements (cons (list (leaf-id n) r) placements))
         (set! panels (cons (make-panel (leaf-view n) r bs
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
       (define sizes (weighted-sizes (for/list ([vx (in-list vis)]) (node-size (cdr vx))) total))
       (define off (if (eq? axis 'lr) (rect-x r) (rect-y r)))
       (define lo  (if (eq? axis 'lr) (rect-y r) (rect-x r)))
       (define hi  (if (eq? axis 'lr) (rect-bottom r) (rect-right r)))
       (define last (sub1 nvis))
       (define prev-i #f)
       (define prev-sz #f)
       (for ([vx (in-list vis)] [idx (in-naturals)] [sz (in-list sizes)])
         (define i (car vx)) (define c (cdr vx))
         (when prev-i
           (set! cuts (cons (cut axis off lo hi path prev-i prev-sz sz) cuts)))
         (define child-outer
           (let ([o (if (< idx last) (remove (if (eq? axis 'lr) 'right 'down) outer) outer)])
             (if (zero? idx) o (remove (if (eq? axis 'lr) 'left 'up) o))))
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

;;; ---------- 拖缝（按格数 → 权重）----------

;; 沿 path 走到 split（path 是孩子下标表）。
(define (node-at-path t path)
  (for/fold ([n t]) ([i (in-list path)]) (list-ref (split-children n) i)))

;; 拖缝：把 seam 左/上可见孩子（cut-index）与其后第一个可见孩子的**权重**按新的格数重分。
;; delta = 格数增量（lr 用列、tb 用行）。两块总权重不变 → 其它兄弟比例不受影响。
;; 与 tree-resize-at 同一条“下一个可见孩子”规则。
(define (tree-resize-seam tree cut delta)
  (define cs (split-children (node-at-path tree (cut-path cut))))
  (define i (cut-index cut))
  (define j (for/first ([k (in-range (add1 i) (length cs))]
                        #:when (node-visible? (list-ref cs k)))
              k))
  (define c (+ (cut-cells-before cut) (cut-cells-after cut)))
  (define w (and j (+ (node-size (list-ref cs i)) (node-size (list-ref cs j)))))
  (cond
    [(or (not j) (zero? c) (not (positive? w))) tree]
    [else
     ;; 权重可以是任意正数；两块总权重不变，按新格数比例分（其它兄弟比例不动）。
     (define eps (/ w 1000))
     (define ni (max eps (min (- w eps) (* w (/ (+ (cut-cells-before cut) delta) c)))))
     (tree-resize-at tree (cut-path cut) i ni (- w ni))]))

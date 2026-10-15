#lang racket

;;; edit-tui/layout-base/region.rkt —— 区域树 + 布局原语（内容无关）
;;;
;;; 布局 = 一棵区域树。所有面板操作都归纳成「在一个区域上重新划分」：
;;;
;;;   split / carve  在一个区域的一侧切出一条，原来的内容留在其余
;;;   remove         去掉一条，其余按比例吃满
;;;   resize         改某条缝的量
;;;   屏幕/区域变尺寸  按 new/old 把整棵子树重排（rescale，可选）
;;;
;;; 目标区域可以是根（= 从屏幕某侧挤占所有 pane），也可以是任意子树（局部化）。
;;; 底层不认识「编辑区 / dock / 浮窗」—— 那只是应用对这些原语的组合。
;;;
;;; 节点：
;;;   leaf  = (leaf owner)         ; owner：内容把手（宿主映射到 view）、可为 #f（空窗）
;;;   split = (split axis kids)    ; axis : 'h（左右）| 'v（上下）
;;;                                 ; kids : (非空 listof (cons size node))
;;;   size  : 正有理数（格数）| 'rest（吃剩余；每层至多一个）
;;;
;;; **不存比例字段**。比例只活在投影这一刻：把一层的 kids 尺寸按比例铺进当前
;;; 矩形的边长。有 'rest → 它是弹性项、数值项固定；无 'rest → 全体按比例缩放。
;;; 尺寸用精确有理数、投影用累积取整，所以反复缩放不会累计漂移。
;;;
;;; 纯函数：结构操作返回新 region，不破坏入参（leaf.owner 仍可变，身份 = 节点 eq?）。

(require "rect.rkt" "panel.rkt")

(provide
 ;; ---------- 节点 ----------
 (struct-out leaf) (struct-out split)
 leaf-node split-node
 ;; ---------- 投影 / 查询 ----------
 region->rects region-rect region-ref region-path region-set region-update
 region-hit region->panels default-deco
 ;; ---------- 接缝 / 方向邻居 ----------
 (struct-out seam) region-seams region-hit-seam
 region-neighbor
 ;; ---------- 结构原语（纯） ----------
 region-split region-split-even region-remove region-remove-node region-resize region-rescale)

;; ==================== 节点 ====================

(struct leaf (owner) #:mutable)          ; owner : any/c（宿主内容把手，可为 #f）
(struct split (axis kids))               ; kids : (listof (cons size node))

;; 空叶（新窗）。
(define (leaf-node [owner #f]) (leaf owner))

(define (split-node axis kids)
  (unless (memq axis '(h v)) (error 'split-node "axis 必须是 'h / 'v，得到 ~a" axis))
  (unless (and (pair? kids) (andmap pair? kids)) (error 'split-node "kids 必须是非空 (cons size node) 表"))
  (split axis kids))

;; ==================== 尺寸分配（比例只在这里生效） ====================

;; E 均分给 n 份（余数给前几份）。
(define (equal-split E n)
  (define q (quotient E n)) (define r (remainder E n))
  (for/list ([i (in-range n)]) (if (< i r) (add1 q) q)))

;; sizes（精确有理数，sum = total）按比例铺成整数，和恰为 E。
;; 累积取整：boundary_i = round(Σ_{j<i} s_j · E / total)。单调、非负、和 = E。
(define (fit-sizes sizes total E)
  (cond
    [(zero? total) (equal-split E (length sizes))]
    [else
     (define (boundary cum) (round (/ (* cum E) total)))
     (let loop ([ss sizes] [cum 0] [out '()])
       (if (null? ss)
           (reverse out)
           (let* ([cum* (+ cum (car ss))]
                  [b (boundary cum*)]
                  [bp (boundary cum)])
             (loop (cdr ss) cum* (cons (- b bp) out)))))])) 

;; 一层 kids 在边长 E 上的整数尺寸，和 = E。
(define (kid-sizes kids E)
  (define rest? (for/or ([k (in-list kids)]) (eq? (car k) 'rest)))
  (define nums (for/list ([k (in-list kids)]) (if (eq? (car k) 'rest) 0 (car k))))
  (define total (apply + nums))
  (cond
    [rest?
     (cond
       [(> total E) (fit-sizes nums total E)]       ; 定尺寸超了 → 压缩、rest 归 0
       [else
        (define fixed (map round nums))
        (define used (apply + fixed))
        (define fixed* (if (> used E) (fit-sizes nums total E) fixed))
        (define rest-size (max 0 (- E (apply + fixed*))))
        (for/list ([k (in-list kids)][s (in-list fixed*)])
          (if (eq? (car k) 'rest) rest-size s))])]
    [else (fit-sizes nums total E)]))               ; 无 rest → 整层按比例

;; ==================== 矩形 ====================

(define (rect-extent rect axis)
  (case axis [(h) (rect-w rect)] [(v) (rect-h rect)]
    [else (error 'rect-extent "axis 必须是 'h / 'v，得到 ~a" axis)]))

;; 沿 axis 把 bounds 按 sizes 依次切成 n 个子矩形。
(define (place-kids bounds axis sizes)
  (case axis
    [(h)
     (let loop ([x (rect-x bounds)][ss sizes][out '()])
       (if (null? ss) (reverse out)
           (loop (+ x (car ss)) (cdr ss)
                 (cons (rect x (rect-y bounds) (car ss) (rect-h bounds)) out))))]
    [(v)
     (let loop ([y (rect-y bounds)][ss sizes][out '()])
       (if (null? ss) (reverse out)
           (loop (+ y (car ss)) (cdr ss)
                 (cons (rect (rect-x bounds) y (rect-w bounds) (car ss)) out))))]
    [else (error 'place-kids "axis 必须是 'h / 'v，得到 ~a" axis)]))

(define (side->axis side)
  (case side [(left right) 'h] [(up down) 'v]
    [else (error 'side->axis "side 必须是 left/right/up/down，得到 ~a" side)]))

;; ==================== 投影 / 查询 ====================

;; → (listof (list path node rect))，只列叶。路径是沿 split 的孩子索引。
(define (region->rects region bounds)
  (let walk ([node region][bounds bounds][path '()])
    (cond
      [(leaf? node) (list (list (reverse path) node bounds))]
      [(split? node)
       (define axis (split-axis node))
       (define kids (split-kids node))
       (define sizes (kid-sizes kids (rect-extent bounds axis)))
       (define rects (place-kids bounds axis sizes))
       (append*
        (for/list ([k (in-list kids)][r (in-list rects)][i (in-naturals)])
          (walk (cdr k) r (cons i path))))]
      [else (error 'region->rects "不是 region: ~a" node)])))

;; 沿路径取节点 / 矩形。
(define (region-ref region path)
  (cond
    [(null? path) region]
    [(split? region)
     (define kids (split-kids region))
     (define i (car path))
     (and (exact-nonnegative-integer? i) (< i (length kids))
          (region-ref (cdr (list-ref kids i)) (cdr path)))]
    [else #f]))

(define (region-rect region bounds path)
  (cond
    [(null? path) bounds]
    [(split? region)
     (define axis (split-axis region))
     (define kids (split-kids region))
     (define rects (place-kids bounds axis (kid-sizes kids (rect-extent bounds axis))))
     (define i (car path))
     (and (exact-nonnegative-integer? i) (< i (length rects))
          (region-rect (cdr (list-ref kids i)) (list-ref rects i) (cdr path)))]
    [else #f]))

;; 按身份找叶的路径（命令持叶引用时用）。
(define (region-path region node)
  (let walk ([r region][path '()])
    (cond
      [(eq? r node) (reverse path)]
      [(split? r)
       (for/or ([k (in-list (split-kids r))][i (in-naturals)])
         (walk (cdr k) (cons i path)))]
      [else #f])))

;; 在路径处替换节点（把原语作用到子树后接回）。
(define (region-set region path node)
  (cond
    [(null? path) node]
    [(split? region)
     (define kids (split-kids region))
     (define i (car path))
     (unless (and (exact-nonnegative-integer? i) (< i (length kids)))
       (error 'region-set "路径越界: ~a" path))
     (split (split-axis region)
            (for/list ([k (in-list kids)][j (in-naturals)])
              (if (= j i)
                  (cons (car k) (region-set (cdr k) (cdr path) node))
                  k)))]
    [else (error 'region-set "路径越界: ~a" path)]))

;; 按身份把一个节点换成 (f node) 的结果（命令最常用：拆 / 关焦点窗）。
;; 返回 (values 新 region 替换后的节点)；节点不在树里 → #f。
(define (region-update region node f)
  (define p (region-path region node))
  (and p
       (let ([n (f (region-ref region p))])
         (values (region-set region p n) n))))

;; (x,y) 命中：返回 (cons path node) | #f。叶互不重叠。
(define (region-hit region bounds x y)
  (for/first ([item (in-list (region->rects region bounds))]
              #:when (rect-contains? (caddr item) x y))
    (cons (car item) (cadr item))))

;; 叶 → panel。deco : (node path rect) → (values borders deep face)。
(define (default-deco node path bounds)
  (values borders-all 0 'window-border))

(define (region->panels region bounds [deco default-deco])
  (for/list ([item (in-list (region->rects region bounds))])
    (define path (car item)) (define node (cadr item)) (define r (caddr item))
    (define-values (b d f) (deco node path r))
    (panel node r b d f)))

;; ==================== 接缝 ====================
;;
;; 接缝 = 一个 split 里相邻两个孩子之间的边界。它是结构上的（树里两个相邻分支），
;; 不是画出来的线。拖动时用 (path, i) 回写：region-resize。
;; axis 'h → 竖缝（pos = x，跨度 [lo,hi) 在 y）；axis 'v → 横缝（pos = y，跨度在 x）。

(struct seam (path i axis pos lo hi) #:transparent)

;; → (listof seam)，按深度优先顺序。
(define (region-seams region bounds)
  (let walk ([node region][bounds bounds][path '()])
    (cond
      [(leaf? node) '()]
      [(split? node)
       (define axis (split-axis node))
       (define kids (split-kids node))
       (define rects (place-kids bounds axis (kid-sizes kids (rect-extent bounds axis))))
       (define lo (case axis [(h) (rect-y bounds)] [(v) (rect-x bounds)]))
       (define hi (case axis [(h) (+ (rect-y bounds) (rect-h bounds))]
                            [(v) (+ (rect-x bounds) (rect-w bounds))]))
       (append
        (for/list ([i (in-range 0 (sub1 (length kids)))])
          (define r (list-ref rects i))
          (seam path i axis
                (case axis [(h) (rect-right r)] [(v) (rect-bottom r)])
                lo hi))
        (append* (for/list ([k (in-list kids)][r (in-list rects)][i (in-naturals)])
                   (walk (cdr k) r (cons i path)))))]
      [else (error 'region-seams "不是 region: ~a" node)])))

;; (x,y) 命中的接缝（容差 tol 格）；返回 seam | #f。
(define (region-hit-seam region bounds x y [tol 1])
  (for/first ([s (in-list (region-seams region bounds))]
              #:when (case (seam-axis s)
                       [(h) (and (<= (abs (- x (seam-pos s))) tol)
                                 (<= (seam-lo s) y) (< y (seam-hi s)))]
                       [(v) (and (<= (abs (- y (seam-pos s))) tol)
                                 (<= (seam-lo s) x) (< x (seam-hi s)))]))
    s))

;; ==================== 方向邻居（移焦点跨接缝） ====================
;;
;; 不必看接缝几何：**树本身就是邻接关系**。从叶沿路径上行，找到第一个
;; 「轴与 dir 同向、且该方向一侧有兄弟」的 split，进入该兄弟子树，再下潜到
;; 垂直方向上离原窗最近的叶。

(define (region-neighbor region bounds node dir)
  (define axis (side->axis dir))
  (define step (if (memq dir '(left up)) -1 1))
  (let walk ([path (region-path region node)])
    (cond
      [(or (not path) (null? path)) #f]
      [else
       (define pp (drop-right path 1))
       (define i (last path))
       (define parent (region-ref region pp))
       (define kids (split-kids parent))
       (define j (+ i step))
       (cond
         [(and (eq? (split-axis parent) axis) (>= j 0) (< j (length kids)))
          (nearest-leaf region bounds (append pp (list j)) (region-rect region bounds path) dir)]
         [else (walk pp)])])))

;; 在兄弟子树里选「沿 dir 最近、垂直方向对齐」的叶。
(define (nearest-leaf region bounds path from-rect dir)
  (define items (region->rects (region-ref region path) (region-rect region bounds path)))
  (define (cy r) (+ (rect-y r) (/ (rect-h r) 2)))
  (define (cx r) (+ (rect-x r) (/ (rect-w r) 2)))
  (define (primary r) (case dir [(right) (rect-x r)] [(left) (- (rect-right r))]
                            [(down) (rect-y r)] [(up) (- (rect-bottom r))]))
  (define (secondary r) (case dir [(right left) (abs (- (cy r) (cy from-rect)))]
                                 [(up down) (abs (- (cx r) (cx from-rect)))]))
  (define best
    (for/fold ([best #f]) ([it (in-list items)])
      (define r (caddr it))
      (cond [(not best) it]
            [(< (primary r) (primary (caddr best))) it]
            [(and (= (primary r) (primary (caddr best)))
                  (< (secondary r) (secondary (caddr best)))) it]
            [else best])))
  (and best (cadr best)))

;; ==================== 结构原语（纯） ====================

;; 在一侧切出一条新叶：新叶占 amount 格（固定），原 region 变弹性（'rest）。
;; 用于「弹 dock」；作用在叶上就是「拆分」。可选 #:owner 一步带入内容。
(define (region-split region bounds side amount #:owner [owner #f])
  (define axis (side->axis side))
  (define E (rect-extent bounds axis))
  (define a (max 0 (min (round amount) E)))
  (define new (leaf-node owner))
  (split axis
         (case side
           [(left)  (list (cons a new) (cons 'rest region))]
           [(right) (list (cons 'rest region) (cons a new))]
           [(up)    (list (cons a new) (cons 'rest region))]
           [(down)  (list (cons 'rest region) (cons a new))]
           [else (error 'region-split "未知 side: ~a" side)])))

;; 均分：原 region 与新叶各占一半（无 rest → 投影按比例，天然保比例）。
(define (region-split-even region axis #:owner [owner #f])
  (define new (leaf-node owner))
  (split axis
         (case axis
           [(h) (list (cons 1 region) (cons 1 new))]
           [(v) (list (cons 1 region) (cons 1 new))]
           [else (error 'region-split-even "axis 必须是 'h / 'v，得到 ~a" axis)])))

;; 去掉路径处的子树；父级只剩一条则塌缩。返回新 region（#f = 全空）。
(define (region-remove region path)
  (cond
    [(null? path) #f]
    [(split? region)
     (define kids (split-kids region))
     (define i (car path))
     (unless (and (exact-nonnegative-integer? i) (< i (length kids)))
       (error 'region-remove "路径越界: ~a" path))
     (define kid (list-ref kids i))
     (define new-kid (if (null? (cdr path)) #f (region-remove (cdr kid) (cdr path))))
     (define kept
       (for/list ([k (in-list kids)][j (in-naturals)])
         (if (= j i) (and new-kid (cons (car k) new-kid)) k)))
     (define kept* (filter values kept))
     (cond
       [(null? kept*) #f]
       [(= 1 (length kept*)) (cdr (car kept*))]
       [else (split (split-axis region) kept*)])]
    [else (error 'region-remove "路径越界: ~a" path)]))

;; 按身份去掉一个叶/子树（命令持节点引用时用）。
(define (region-remove-node region node)
  (define p (region-path region node))
  (and p (region-remove region p)))

;; 改某层第 i 份的尺寸（数值项；'rest 不动）。不传 bounds：尺寸是相对量，投影时再落。
(define (region-resize region path i delta)
  (unless (split? region) (error 'region-resize "路径越界: ~a" path))
  (define kids (split-kids region))
  (cond
    [(null? path)
     (unless (< i (length kids)) (error 'region-resize "孩子索引越界: ~a" i))
     (split (split-axis region)
            (for/list ([k (in-list kids)][j (in-naturals)])
              (if (= j i)
                  (cons (let ([s (car k)]) (if (eq? s 'rest) s (max 0 (+ s delta)))) (cdr k))
                  k)))]
    [else
     (define j (car path))
     (unless (< j (length kids)) (error 'region-resize "路径越界: ~a" path))
     (define k (list-ref kids j))
     (split (split-axis region)
            (for/list ([kk (in-list kids)][idx (in-naturals)])
              (if (= idx j)
                  (cons (car kk) (region-resize (cdr kk) (cdr path) i delta))
                  kk)))]))

;; 把 region 从 old-rect 映射到 new-rect：数值尺寸乘 new/old（'rest 不变），递归。
;; 投影本身已按比例适配，所以这是「把缩放烘焙进存储尺寸」的可选操作。
(define (region-rescale region old-rect new-rect)
  (cond
    [(leaf? region) region]
    [(split? region)
     (define axis (split-axis region))
     (define kids (split-kids region))
     (define old-e (rect-extent old-rect axis))
     (define new-e (rect-extent new-rect axis))
     (define f (if (zero? old-e) 1 (/ new-e old-e)))
     (define kids* (for/list ([k (in-list kids)])
                     (cons (let ([s (car k)]) (if (eq? s 'rest) s (* s f))) (cdr k))))
     (define old-sub (place-kids old-rect axis (kid-sizes kids old-e)))
     (define new-sub (place-kids new-rect axis (kid-sizes kids* new-e)))
     (split axis
            (for/list ([k (in-list kids*)][os (in-list old-sub)][ns (in-list new-sub)])
              (cons (car k) (region-rescale (cdr k) os ns))))]
    [else (error 'region-rescale "不是 region: ~a" region)]))

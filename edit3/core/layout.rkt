#lang racket

;;; edit3/layout.rkt —— 纯布局求解器 + 几何 + 命中 + 树手术
;;;
;;; 求解规则（DESIGN §4）：
;;;   1. extent < Σmin        → 全取 min（溢出也不压到 min 以下）
;;;   2. free = extent - Σbasis
;;;   3. free>0 → 按 grow 分；free<0 → 按 shrink 分；free=0 → 就是 basis
;;;   4. 抬到 item.min；若因此超出 extent，从“高于 min 的余量”按比例削回
;;; 运行时改尺寸 = 只改两个相邻 item 的 basis（Σbasis 不变 ⇒ 其它项精确不动）。
;;; 容器 resize 只改 extent，靠 grow/shrink 分配。min 沿轴累加，所以外层压不塌里层。

(provide
 ;; 求解
 solve-axis min-size axis-min
 layout hit rect-contains? rect-bounds
 float-rect
 ;; 手术
 layout-split-tile layout-remove-wid layout-remove-vid
 layout-resize-boundary layout-set-bases
 layout-fresh-wid layout-tile-vid layout-set-tile-vid layout-tile-border
 layout-find-path layout-add-side layout-add-adjacent
 ;; 查询
 node-wids layout-vids layout-has? layout-has-wid? layout-wid-of-vid)

(require "state.rkt"
         racket/list)

(define min-tile 2)
(define (clamp v lo hi) (max lo (min hi v)))

;;; ---------- 最小尺寸（沿轴累加） ----------
;;; 叶子取自身的 min（编辑窗 2×2、面板 1×1）；split 沿轴相加，
;;; 相邻子项之间预留 1 格给分隔线（不占内容）。

(define (min-size node)
  (cond
    [(not node) (values 0 0)]
    [(tile? node) (values (car (tile-min node)) (cdr (tile-min node)))]
    [(split? node)
     (define its (split-items node))
     (define seps (max 0 (sub1 (length its))))
     (define-values (w h)
       (for/fold ([mw 0] [mh 0]) ([it (in-list its)])
         (define-values (w h) (min-size (item-child it)))
         (if (eq? (split-axis node) 'h)
             (values (+ mw w) (max mh h))
             (values (max mw w) (+ mh h)))))
     (if (eq? (split-axis node) 'h) (values (+ w seps) h) (values w (+ h seps)))]
    [else (values min-tile min-tile)]))

(define (axis-min node axis)
  (define-values (w h) (min-size node))
  (if (eq? axis 'h) w h))

;;; ---------- 一维分配 ----------

(define (last-grow-index items)
  (let loop ([is (reverse (range (length items)))])
    (cond [(null? is) 0]
          [(positive? (item-grow (list-ref items (car is)))) (car is)]
          [else (loop (cdr is))])))

(define (solve-axis items extent)
  (define mins (map item-min items))
  (define min-sum (for/sum ([m (in-list mins)]) m))
  (cond
    [(<= extent min-sum) mins]
    [else
     (define basis (map item-basis items))
     (define free (- extent (for/sum ([b (in-list basis)]) b)))
     (define (share-by w)
       (define s (for/sum ([x (in-list w)]) x))
       (for/list ([x (in-list w)]) (if (zero? s) 0 (quotient (* free x) s))))
     (define share (cond [(> free 0) (share-by (map item-grow items))]
                         [(< free 0) (share-by (map item-shrink items))]
                         [else (for/list ([it (in-list items)]) 0)]))
     (define lifted (for/list ([b (in-list basis)] [s (in-list share)] [m (in-list mins)])
                      (max (+ b s) m)))
     (define sum (for/sum ([l (in-list lifted)]) l))
     (cond
       [(> sum extent)                    ; 抬 min 抬过头 → 从余量里削回
        (define deficit (- sum extent))
        (define slack (for/list ([l (in-list lifted)] [m (in-list mins)]) (- l m)))
        (define slack-sum (for/sum ([x (in-list slack)]) x))
        (if (zero? slack-sum)
            lifted
            (for/list ([l (in-list lifted)] [x (in-list slack)])
              (- l (min x (ceiling (/ (* x deficit) slack-sum))))))]
       [(< sum extent)                    ; 取整余量 → 给最后一个 grow 段
        (define rem (- extent sum))
        (define k (last-grow-index items))
        (for/list ([l (in-list lifted)] [i (in-naturals)]) (if (= i k) (+ l rem) l))]
       [else lifted])]))

;;; ---------- 几何求解 ----------

(define (rect-contains? r x y)
  (and (<= (rect-x r) x) (< x (+ (rect-x r) (rect-w r)))
       (<= (rect-y r) y) (< y (+ (rect-y r) (rect-h r)))))

;; 一组矩形的包围盒（空 → #f）。用 apply min/max 保持精确数（不能用 ±inf.0 种子，
;; 否则结果会变 flonum）。
(define (rect-bounds rs)
  (cond
    [(null? rs) #f]
    [else
     (define x0 (apply min (map rect-x rs)))
     (define y0 (apply min (map rect-y rs)))
     (define x1 (apply max (map (lambda (r) (+ (rect-x r) (rect-w r))) rs)))
     (define y1 (apply max (map (lambda (r) (+ (rect-y r) (rect-h r))) rs)))
     (rect x0 y0 (- x1 x0) (- y1 y0))]))

(define (float-rect rel f W H)
  (define a (float-anchor f))
  (define sz (float-size f))
  (define w (min (car sz) W))
  (define h (min (cdr sz) H))
  (define base-x
    (case (anchor-h a)
      [(left)    (rect-x rel)]
      [(right)   (- (+ (rect-x rel) (rect-w rel)) w)]
      [(center)  (+ (rect-x rel) (quotient (- (rect-w rel) w) 2))]
      [else      (rect-x rel)]))
  (define base-y
    (case (anchor-v a)
      [(top)     (rect-y rel)]
      [(bottom)  (- (+ (rect-y rel) (rect-h rel)) h)]
      [(center)  (+ (rect-y rel) (quotient (- (rect-h rel) h) 2))]
      [else      (rect-y rel)]))
  (rect (clamp (+ base-x (anchor-dx a)) 0 (max 0 (- W w)))
        (clamp (+ base-y (anchor-dy a)) 0 (max 0 (- H h)))
        w h))

;; layout : tiling floats size -> geometry
(define (layout tl floats size)
  (define W (car size))
  (define H (cdr size))
  (define ps '())
  (define hs '())
  (define tiled (make-hash))            ; wid -> rect（浮窗锚点解析用）

  (define (walk node r path)
    (cond
      [(not node) (void)]
      [(tile? node) (hash-set! tiled (tile-wid node) r)
       (set! ps (cons (placement (tile-wid node) (tile-vid node) r 0) ps))]
      [(split? node)
       (define axis (split-axis node))
       (define items (split-items node))
       (define n (length items))
       (define seps (max 0 (sub1 n)))
       (define E (if (eq? axis 'h) (rect-w r) (rect-h r)))
       (define lens (solve-axis items (max 0 (- E seps))))   ; 预留 n-1 条缝
       (define mins (map item-min items))
       (define bases (map item-basis items))
       (define lo (if (eq? axis 'h) (rect-y r) (rect-x r)))
       (define hi (+ lo (if (eq? axis 'h) (rect-h r) (rect-w r))))
       (define off 0)
       (for ([it (in-list items)] [len (in-list lens)] [i (in-naturals)])
         (define cr (if (eq? axis 'h)
                        (rect (+ (rect-x r) off) (rect-y r) len (rect-h r))
                        (rect (rect-x r) (+ (rect-y r) off) (rect-w r) len)))
         (walk (item-child it) cr (append path (list i)))
         (set! off (+ off len))
         (when (< i (sub1 n))            ; 缝：占 1 格，不在任一窗内容里
           (define pos (+ (if (eq? axis 'h) (rect-x r) (rect-y r)) off))
           (set! hs (cons (handle 'boundary
                                  (if (eq? axis 'h)
                                      (rect pos lo 1 (- hi lo))
                                      (rect lo pos (- hi lo) 1))
                                  0 (list axis path i lens mins bases))
                          hs))
           (set! off (+ off 1))))]
      [else (void)]))

  (walk (tiling-root tl) (rect 0 0 W H) '())

  ;; 浮窗：表头 = 最上（z 最大）；rel 解析用已布好的 tiled。
  (define (rel-rect a)
    (cond [(eq? (anchor-rel a) 'screen) (rect 0 0 W H)]
          [(hash-ref tiled (anchor-rel a) #f)]
          [else (rect 0 0 W H)]))
  (for ([f (in-list (reverse floats))] [i (in-naturals)])
    (define z (+ 1 i))
    (define r (float-rect (rel-rect (float-anchor f)) f W H))
    (define x (rect-x r)) (define y (rect-y r))
    (define w (rect-w r)) (define h (rect-h r))
    (set! ps (cons (placement (float-wid f) (float-vid f) r z) ps))
    ;; 整块移动（先入列），再压四角缩放（后入列 → hit 同 z 时角优先）
    (set! hs (cons (handle 'float-move r z (list (float-wid f) 'move)) hs))
    (for ([e (in-list '((nw 0 0) (ne 1 0) (sw 0 1) (se 1 1)))])
      (match-define (list edge kx ky) e)
      (set! hs (cons (handle (string->symbol (format "float-resize-~a" edge))
                             (rect (+ x (* kx (sub1 w))) (+ y (* ky (sub1 h))) 2 2)
                             z (list (float-wid f) edge))
                     hs))))

  (geometry (reverse ps) hs W H))

;;; ---------- 命中 ----------

;; 最上层先：handle 与 placement 比 z，同 z 时手柄优先（缝可拖）。
(define (hit g x y)
  (define best-p
    (for/fold ([best #f]) ([p (in-list (geometry-placements g))])
      (if (and (rect-contains? (placement-rect p) x y)
               (or (not best) (> (placement-z p) (placement-z best))))
          p best)))
  (define best-h
    (for/fold ([best #f]) ([h (in-list (geometry-handles g))])
      (if (and (rect-contains? (handle-rect h) x y)
               (or (not best) (> (handle-z h) (handle-z best))))
          h best)))
  (cond
    [(and best-h (or (not best-p) (>= (handle-z best-h) (placement-z best-p)))) best-h]
    [best-p best-p]
    [else #f]))

;;; ---------- 树手术 ----------

(define (node-wids node)
  (cond
    [(not node) '()]
    [(tile? node) (list (tile-wid node))]
    [(split? node) (append* (for/list ([it (in-list (split-items node))]) (node-wids (item-child it))))]
    [else '()]))

;; 分配一个新 wid：现有最大整 wid + 1。
(define (layout-fresh-wid tl)
  (add1 (for/fold ([m -1]) ([w (in-list (node-wids (tiling-root tl)))])
          (if (number? w) (max m w) m))))

;; 某 wid 的 tile 显示的 vid（没有 → #f）。
(define (layout-tile-vid tl wid)
  (define (go node)
    (cond
      [(not node) #f]
      [(tile? node) (and (eqv? wid (tile-wid node)) (tile-vid node))]
      [(split? node) (for/or ([it (in-list (split-items node))]) (go (item-child it)))]
      [else #f]))
  (go (tiling-root tl)))

;; 某 wid 的 tile 边框 face（没有 → #f）。
(define (layout-tile-border tl wid)
  (define (go node)
    (cond
      [(not node) #f]
      [(tile? node) (and (eqv? wid (tile-wid node)) (tile-border node))]
      [(split? node) (for/or ([it (in-list (split-items node))]) (go (item-child it)))]
      [else #f]))
  (go (tiling-root tl)))

(define (layout-set-tile-vid tl wid vid)
  (define (go node)
    (cond
      [(not node) node]
      [(tile? node) (if (eqv? wid (tile-wid node)) (struct-copy tile node [vid vid]) node)]
      [(split? node) (split (split-axis node)
                            (for/list ([it (in-list (split-items node))])
                              (struct-copy item it [child (go (item-child it))])))]
      [else node]))
  (tiling (go (tiling-root tl))))

;; 按 path 找到 split，把 items 交给 f 变换。
(define (map-split-at node path f)
  (cond
    [(not node) #f]
    [(null? path) (if (split? node) (split (split-axis node) (f (split-items node))) node)]
    [(split? node)
     (define i (car path))
     (split (split-axis node)
            (for/list ([it (in-list (split-items node))] [j (in-naturals)])
              (if (= i j)
                  (struct-copy item it [child (map-split-at (item-child it) (cdr path) f)])
                  it)))]
    [else node]))

;; 移动 path 处 split 的第 index / index+1 段之间的缝：basis_i += delta, basis_{i+1} -= delta。
;; （Σbasis 不变 → 其它段精确不动；min 由 solver 保证，这里只管意图。）
;; 注意：这是**增量**版，连续调用会累加；拖拽要用 layout-set-bases（从原值算）。
(define (layout-resize-boundary tl path index delta)
  (tiling (map-split-at (tiling-root tl) path
                        (lambda (items)
                          (for/list ([it (in-list items)] [i (in-naturals)])
                            (cond [(= i index) (struct-copy item it [basis (+ (item-basis it) delta)])]
                                  [(= i (add1 index)) (struct-copy item it [basis (- (item-basis it) delta)])]
                                  [else it]))))))

;; 直接设两段 basis（拖拽用：每次从按下时的原 basis + 总位移算，不漂）。
(define (layout-set-bases tl path index bi bj)
  (tiling (map-split-at (tiling-root tl) path
                        (lambda (items)
                          (for/list ([it (in-list items)] [i (in-naturals)])
                            (cond [(= i index) (struct-copy item it [basis bi])]
                                  [(= i (add1 index)) (struct-copy item it [basis bj])]
                                  [else it]))))))

;; 把 wid 的 tile 换成 [原 tile | new-node]，两段等分（basis=1,grow/shrink=1 → 任意 extent 都平分）。
(define (layout-split-tile tl wid axis new-node first?)
  (define (mk child) (item 1 1 1 (axis-min child axis) child))
  (define (go node)
    (cond
      [(not node) #f]
      [(tile? node)
       (if (eqv? wid (tile-wid node))
           (split axis (if first?
                           (list (mk new-node) (mk node))
                           (list (mk node) (mk new-node))))
           node)]
      [(split? node)
       (split (split-axis node)
              (for/list ([it (in-list (split-items node))])
                (struct-copy item it [child (go (item-child it))])))]
      [else node]))
  (tiling (go (tiling-root tl))))

;; 删 wid 的 tile；空容器收拢。
(define (layout-remove-wid tl wid)
  (define (go node)
    (cond
      [(not node) #f]
      [(tile? node) (if (eqv? wid (tile-wid node)) #f node)]
      [(split? node)
       (define kept
         (for/fold ([acc '()]) ([it (in-list (split-items node))])
           (define c (go (item-child it)))
           (if c (append acc (list (struct-copy item it [child c]))) acc)))
       (cond [(null? kept) #f]
             [(null? (cdr kept)) (item-child (car kept))]
             [else (split (split-axis node) kept)])]
      [else #f]))
  (tiling (go (tiling-root tl))))

;;; ---------- 查询（平铺树） ----------

;; 树里所有可见 vid（跳过空 tile）。
(define (layout-vids tl)
  (for/list ([w (in-list (node-wids (tiling-root tl)))]
             #:when (layout-tile-vid tl w))
    (layout-tile-vid tl w)))

(define (layout-has-wid? tl wid) (and (memv wid (node-wids (tiling-root tl))) #t))
(define (layout-has? tl vid) (and (memv vid (layout-vids tl)) #t))

;; 显示某 vid 的第一个 tile（不在 → #f）。
(define (layout-wid-of-vid tl vid)
  (for/first ([w (in-list (node-wids (tiling-root tl)))]
              #:when (eqv? vid (layout-tile-vid tl w)))
    w))

;; 删所有显示该 vid 的 tile（同 view 多位置 → 一次全清）。
(define (layout-remove-vid tl vid)
  (for/fold ([t tl]) ([w (in-list (node-wids (tiling-root tl)))]
                      #:when (eqv? vid (layout-tile-vid tl w)))
    (layout-remove-wid t w)))

;;; ---------- 区域贴边手术 ----------

;; 到某 wid tile 的路径（indices）；不在 → #f。
(define (layout-find-path tl wid)
  (define (go node)
    (cond
      [(not node) #f]
      [(tile? node) (and (eqv? wid (tile-wid node)) '())]
      [(split? node)
       (for/first ([it (in-list (split-items node))] [i (in-naturals)]
                   #:when (go (item-child it)))
         (cons i (go (item-child it))))]
      [else #f]))
  (go (tiling-root tl)))

(define (side-axis side) (if (memq side '(left right)) 'h 'v))
(define (side-first? side) (and (memq side '(left top)) #t))

;; 包住整棵树：新区域成为根的一侧（anchor 'root）。
(define (layout-add-side tl child side size)
  (define axis (side-axis side))
  (define it (item size 0 0 (axis-min child axis) child))
  (define root (tiling-root tl))
  (cond
    [(not root) (tiling child)]
    [else
     (define root-it (item 1 1 1 (axis-min root axis) root))
     (tiling (split axis (if (side-first? side)
                             (list it root-it)
                             (list root-it it))))]))

;; 在 target tile 旁插入一段（anchor 'main）：同轴则插到父 split，异轴则包一层。
(define (layout-add-adjacent tl target side size child)
  (define axis (side-axis side))
  (define new-it (item size 0 0 (axis-min child axis) child))
  (define (wrap node)
    (define it (item 1 1 1 (axis-min node axis) node))
    (split axis (if (side-first? side) (list new-it it) (list it new-it))))
  (define (go node)
    (cond
      [(not node) node]
      [(tile? node) (if (eqv? target (tile-wid node)) (wrap node) node)]
      [(split? node)
       (define items (split-items node))
       (define idx
         (for/first ([it (in-list items)] [i (in-naturals)]
                     #:when (and (tile? (item-child it))
                                 (eqv? target (tile-wid (item-child it)))))
           i))
       (cond
         [idx
          (define before (take items idx))
          (define mid (list-ref items idx))
          (define after (drop items (add1 idx)))
          (if (eq? (split-axis node) axis)
              (split axis (if (side-first? side)
                              (append before (list new-it mid) after)
                              (append before (list mid new-it) after)))
              (split (split-axis node)
                     (append before
                             (list (struct-copy item mid [child (wrap (item-child mid))]))
                             after)))]
         [else
          (split (split-axis node)
                 (for/list ([it (in-list items)])
                   (if (memv target (node-wids (item-child it)))
                       (struct-copy item it [child (go (item-child it))])
                       it)))])]
      [else node]))
  (tiling (go (tiling-root tl))))

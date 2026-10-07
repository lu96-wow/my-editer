#lang racket

;;; lab-rebuild/kernel/frame.rkt —— 工作区：带角色的窗格树 + 纯派生布局。
;;;
;;; frame 只存结构（root）；active 焦点在 focus.rkt。
;;; layout 是纯函数，缓存按 frame 值 memo，无需手工失效（解 I7）。
;;;
;;; **两层布局**：
;;;   外层  root = #f | leaf | (split dir size a b)   窗格之间（可 swap / resize）
;;;   叶内  inner = vid | (isplit dir size a b)       一个叶子里多个 view 的固定布局
;;; 叶子内布局是**固定**的：外层的 split/resize/swap 只作用在叶与叶之间，
;;; 叶内尺寸存在 isplit 里、不随外层操作改变（特性按需构造，如「原文 | 译文」）。
;;; 叶子内每个 view 仍然各自可聚焦 / 命中 / 渲染 —— 布局会把叶子的区域展开成多块 rectangle。

(require "editor-api.rkt")

(provide (struct-out leaf) (struct-out split) (struct-out frame)
         (struct-out area) (struct-out isplit)
         frame-empty frame-new frame-root frame-set-root
         frame-leaves frame-find frame-contains?
         frame-split frame-remove frame-drop-leaf frame-replace frame-replace-view
         frame-swap frame-swap-leaf frame-resize
         frame-set-leaf frame-group frame-ungroup frame->leaf-rects
         leaf-views leaf-vid leaf-inner leaf-first-vid
         isplit* inner-views inner-has? inner-erase
         area-split workspace-main-area frame->rectangles)

(struct area (x y w h) #:transparent)

;; 按 dir 把 area 切成两段（第一段 size）。
(define (area-split a dir size)
  (case dir
    [(lr) (values (area (area-x a) (area-y a) size (area-h a))
                  (area (+ (area-x a) size) (area-y a) (- (area-w a) size) (area-h a)))]
    [(tb) (values (area (area-x a) (area-y a) (area-w a) size)
                  (area (area-x a) (+ (area-y a) size) (area-w a) (- (area-h a) size)))]
    [else (error 'area-split "dir 必须是 'lr / 'tb")]))

;; 屏尺寸 + 左栏状态 → (values 左栏宽 主区区域)。
;; layout / focus 几何 / pane-resize 共用，避免三处各算一套（曾出现 x 偏移与 clamp 不一致）。
(define (workspace-main-area w h sidebar? sidebar-width)
  (define sw (if sidebar? (min sidebar-width (max 0 (- w 1))) 0))
  (values sw (area sw 0 (max 1 (- w sw)) (max 1 (sub1 h)))))

;;; ================= 叶子内布局（固定） =================
;;; inner = vid | (isplit dir size a b)
;;;   dir  : 'lr | 'tb
;;;   size : #f（均分）| 第一段尺寸
;;; 裸 vid 是「单 view 叶子」，保持与旧模型兼容。

(struct isplit (dir size a b) #:transparent)

;; 便捷构造： (isplit* 'lr vid1 vid2)，size 省略 = 均分。
(define (isplit* dir a b [size #f]) (isplit dir size a b))

(define (inner-views x)
  (cond [(vid? x) (list x)]
        [else (append (inner-views (isplit-a x)) (inner-views (isplit-b x)))]))

(define (inner-has? x vid)
  (cond [(vid? x) (eqv? x vid)]
        [else (or (inner-has? (isplit-a x) vid) (inner-has? (isplit-b x) vid))]))

;; 删掉 vid；全空 → #f，否则返回（可能收拢过的）inner。
(define (inner-erase x vid)
  (cond
    [(vid? x) (if (eqv? x vid) #f x)]
    [else
     (define a (inner-erase (isplit-a x) vid))
     (define b (inner-erase (isplit-b x) vid))
     (cond [(and a b) (struct-copy isplit x [a a] [b b])]
           [a a] [b b] [else #f])]))

;; 对每个 vid 施加 f（用于换 id / swap）。
(define (inner-map x f)
  (cond [(vid? x) (f x)]
        [else (struct-copy isplit x [a (inner-map (isplit-a x) f)]
                                   [b (inner-map (isplit-b x) f)])]))

(define (vid? x) (exact-nonnegative-integer? x))

;;; ================= 外层窗格树 =================

(struct leaf (inner role) #:transparent)
(struct split (dir size a b) #:transparent)
(struct frame (root) #:transparent)
;; root : #f | leaf | split

(define (frame-empty) (frame #f))
(define (frame-new root) (frame root))
(define (frame-set-root f r) (frame r))

(define (leaf-views l) (inner-views (leaf-inner l)))
(define (leaf-first-vid l) (car (leaf-views l)))
;; 兼容旧调用：叶子的第一个 view。
(define (leaf-vid l) (leaf-first-vid l))

(define (frame-leaves f)
  (define (go n)
    (cond [(not n) '()]
          [(leaf? n) (list n)]
          [else (append (go (split-a n)) (go (split-b n)))]))
  (go (frame-root f)))

(define (frame-contains? f vid)
  (for/or ([l (in-list (frame-leaves f))]) (inner-has? (leaf-inner l) vid)))

(define (frame-find f vid)
  (for/first ([l (in-list (frame-leaves f))] #:when (inner-has? (leaf-inner l) vid)) l))

;; 把 vid 所在的叶换成内层组合后的叶 —— 特性用来把若干 view 合成一个叶子。
(define (frame-set-leaf f vid new-leaf)
  (define (go n)
    (cond [(not n) #f]
          [(leaf? n) (if (inner-has? (leaf-inner n) vid) new-leaf n)]
          [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 把 vid 的叶换成 node(dir, 该叶, leaf new-vid)——外层分屏，叶内布局保持不动。
(define (frame-split f vid dir new-vid [size #f])
  (define (go n)
    (cond
      [(not n) (leaf vid 'edit)]
      [(leaf? n)
       (if (inner-has? (leaf-inner n) vid) (split dir size n (leaf new-vid 'edit)) n)]
      [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 删掉 vid：叶内还有别的 view 就只摘掉它，空了才删整个叶。
(define (frame-remove f vid)
  (define (go n)
    (cond
      [(not n) #f]
      [(leaf? n)
       (define inner (inner-erase (leaf-inner n) vid))
       (if inner (leaf inner (leaf-role n)) #f)]
      [else
       (define a (go (split-a n)))
       (define b (go (split-b n)))
       (cond [(and a b) (struct-copy split n [a a] [b b])]
             [a a] [b b] [else #f])]))
  (frame (go (frame-root f))))

;; 删掉 vid 所在的**整个叶**（叶内布局是一个整体，close 用）。
(define (frame-drop-leaf f vid)
  (define (go n)
    (cond
      [(not n) #f]
      [(leaf? n) (if (inner-has? (leaf-inner n) vid) #f n)]
      [else
       (define a (go (split-a n)))
       (define b (go (split-b n)))
       (cond [(and a b) (struct-copy split n [a a] [b b])]
             [a a] [b b] [else #f])]))
  (frame (go (frame-root f))))

;; 按 leaf 身份删除（frame-group 用），不按 vid。
(define (frame-remove-leaf f l)
  (define (go n)
    (cond
      [(not n) #f]
      [(leaf? n) (if (eq? n l) #f n)]
      [else
       (define a (go (split-a n)))
       (define b (go (split-b n)))
       (cond [(and a b) (struct-copy split n [a a] [b b])]
             [a a] [b b] [else #f])]))
  (frame (go (frame-root f))))

;; 把 vid 所在的叶整体替换成 new-node（可以是叶，也可以是 split —— ungroup 用）。
(define (frame-replace f vid new-node)
  (define (go n)
    (cond [(not n) #f]
          [(leaf? n) (if (inner-has? (leaf-inner n) vid) new-node n)]
          [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 把某个 view 换成另一个 view（叶子内保结构）—— e-show-view 'replace 用。
(define (frame-replace-view f old new)
  (define (go n)
    (cond [(not n) #f]
          [(leaf? n) (leaf (inner-map (leaf-inner n) (λ (v) (if (eqv? v old) new v)))
                           (leaf-role n))]
          [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; swap 两个 view 的位置（跨叶 / 叶内都行，结构不动）。
(define (frame-swap f v1 v2)
  (define (go n)
    (cond [(not n) #f]
          [(leaf? n)
           (leaf (inner-map (leaf-inner n)
                            (λ (v) (cond [(eqv? v v1) v2] [(eqv? v v2) v1] [else v])))
                 (leaf-role n))]
          [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
  (frame (go (frame-root f))))

;; 整叶交换位置：两个叶子（含各自的叶内布局）互换位置，结构随内容一起走。
;; 这是 pane-move 的正确粒度——只换单个 view 会把组合叶拆开（错位）。
(define (frame-swap-leaf f v1 v2)
  (define l1 (frame-find f v1))
  (define l2 (frame-find f v2))
  (cond
    [(or (not l1) (not l2) (eq? l1 l2)) f]
    [else
     (define (go n)
       (cond [(not n) #f]
             [(leaf? n) (cond [(eq? n l1) l2] [(eq? n l2) l1] [else n])]
             [else (struct-copy split n [a (go (split-a n))] [b (go (split-b n))])]))
     (frame (go (frame-root f)))]))

;; 合并两个叶为一个叶：inner1 ⊕ inner2（dir 固定，size 可给）。
(define (frame-group f v1 v2 dir [size #f])
  (define l1 (frame-find f v1))
  (define l2 (frame-find f v2))
  (cond
    [(or (not l1) (not l2) (eq? l1 l2)) f]
    [else
     (define combined (leaf (isplit* dir (leaf-inner l1) (leaf-inner l2) size) (leaf-role l1)))
     (frame-replace (frame-remove-leaf f l2) v1 combined)]))

;; 拆掉叶内布局：把 inner 树展开成外层 split 树的叶（group 的逆）。
(define (frame-ungroup f vid)
  (define l (frame-find f vid))
  (cond
    [(or (not l) (vid? (leaf-inner l))) f]
    [else
     (define (inner->node x)
       (cond [(vid? x) (leaf x (leaf-role l))]
             [else (split (isplit-dir x) (isplit-size x)
                          (inner->node (isplit-a x)) (inner->node (isplit-b x)))]))
     (frame-replace f vid (inner->node (leaf-inner l)))]))

(define (node-contains? n vid)
  (cond [(leaf? n) (inner-has? (leaf-inner n) vid)]
        [else (or (node-contains? (split-a n) vid) (node-contains? (split-b n) vid))]))

;; 沿 vid 所在路径找最近的同向 node，把第一段尺寸调 delta。axis: 'width | 'height。
(define (frame-resize f vid axis delta area)
  (define target (if (eq? axis 'width) 'lr 'tb))
  (define (go node a)
    (cond
      [(leaf? node) node]
      [else
       (define dir (split-dir node))
       (define e (max 2 (if (eq? dir 'lr) (area-w a) (area-h a))))
       (define s (max 1 (or (split-size node) (quotient e 2))))
       (define in-a? (node-contains? (split-a node) vid))
       (define in-b? (node-contains? (split-b node) vid))
       (cond
         [(and (eq? dir target) (or in-a? in-b?))
          (struct-copy split node [size (max 1 (min (- e 2) (+ s (if in-a? delta (- delta)))))] )]
         [else
          (define-values (a* b*) (area-split a dir s))
          (struct-copy split node
                       [a (if in-a? (go (split-a node) a*) (split-a node))]
                       [b (if in-b? (go (split-b node) b*) (split-b node))])])]))
  (frame (go (frame-root f) area)))

;;; ================= 区域 → rectangle =================

;; → (values (listof rectangle) (listof rectangle))。bar 用 view-id 'bar。
(define (frame->rectangles f reg)
  (define split-gap 1)
  (define (go n a)
    (cond
      [(not n) (values '() '())]
      [(leaf? n) (inner->rectangles (leaf-inner n) a)]
      [else
       (define dir (split-dir n))
       (define total (if (eq? dir 'lr) (area-w a) (area-h a)))
       (define size (max 1 (or (split-size n) (quotient (- total split-gap) 2))))
       (define-values (a* b) (area-split a dir size))
       (define b* (if (eq? dir 'lr)
                      (area (+ (area-x b) split-gap) (area-y b) (max 1 (- (area-w b) split-gap)) (area-h b))
                      (area (area-x b) (+ (area-y b) split-gap) (area-w b) (max 1 (- (area-h b) split-gap)))))
       (define bar (if (eq? dir 'lr)
                       (rectangle 'bar (area-x b) (area-y a) split-gap (area-h a) 1)
                       (rectangle 'bar (area-x a) (area-y b) (area-w a) split-gap 1)))
       (define-values (r1 _b1) (go (split-a n) a*))
       (define-values (r2 _b2) (go (split-b n) b*))
       (values (append r1 r2) (list bar))]))
  (go (frame-root f) reg))

;; 外层窗格树 → (listof (cons leaf rectangle))：一个叶子一块（整叶包围盒）。
;; pane-move / 方向导航按**叶子整体**算，不受叶内 view 影响；与 frame->rectangles 同 gap。
(define (frame->leaf-rects f reg)
  (define split-gap 1)
  (define (go n a)
    (cond
      [(not n) '()]
      [(leaf? n)
       (list (cons n (rectangle (leaf-vid n) (area-x a) (area-y a) (area-w a) (area-h a) 0)))]
      [else
       (define dir (split-dir n))
       (define total (if (eq? dir 'lr) (area-w a) (area-h a)))
       (define size (max 1 (or (split-size n) (quotient (- total split-gap) 2))))
       (define-values (a* b) (area-split a dir size))
       (define b* (if (eq? dir 'lr)
                      (area (+ (area-x b) split-gap) (area-y b) (max 1 (- (area-w b) split-gap)) (area-h b))
                      (area (area-x b) (+ (area-y b) split-gap) (area-w b) (max 1 (- (area-h b) split-gap)))))
       (append (go (split-a n) a*) (go (split-b n) b*))]))
  (go (frame-root f) reg))

;; 叶子内固定布局 → rectangle：每个 view 一块，同层相邻之间留 1 格 gap（bar）。
(define (inner->rectangles inner a)
  (define gap 1)
  (cond
    [(vid? inner)
     (values (list (rectangle inner (area-x a) (area-y a) (area-w a) (area-h a) 0)) '())]
    [else
     (define dir (isplit-dir inner))
     (define total (if (eq? dir 'lr) (area-w a) (area-h a)))
     (define size (max 1 (or (isplit-size inner) (quotient (- total gap) 2))))
     (define-values (a* b) (area-split a dir size))
     (define b* (if (eq? dir 'lr)
                    (area (+ (area-x b) gap) (area-y b) (max 1 (- (area-w b) gap)) (area-h b))
                    (area (area-x b) (+ (area-y b) gap) (area-w b) (max 1 (- (area-h b) gap)))))
     (define bar (if (eq? dir 'lr)
                     (rectangle 'bar (area-x b) (area-y a) gap (area-h a) 1)
                     (rectangle 'bar (area-x a) (area-y b) (area-w a) gap 1)))
     (define-values (r1 b1) (inner->rectangles (isplit-a inner) a*))
     (define-values (r2 b2) (inner->rectangles (isplit-b inner) b*))
     (values (append r1 r2) (append b1 (list bar) b2))]))

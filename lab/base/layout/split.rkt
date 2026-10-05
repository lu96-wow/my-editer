#lang racket

(require "../../../core/editor.rkt"
         "area.rkt")

;;; lab-rebuild/base/layout/split.rkt —— 主区分屏树（骨架）
;;;
;;; 纯数据 + 纯函数：树只描述「怎么切」，铺进一块 area 得到窗格矩形 + 分割条。
;;; 叶子绑定 vid（一块屏幕格显示哪个 view）。不认识 editor / 焦点 / 命令。
;;;
;;;   leaf : 一个编辑窗格（vid）
;;;   node : dir（'lr 左右 | 'tb 上下）+ size（第一段尺寸；#f = 均分）+ 两子树
;;;
;;; tree->rectangles → (values 窗格矩形 分割条 尺寸警告)：
;;;   - 两段之间留 split-gap 格的分割条（bar），供鼠标拖拽调尺寸 / 视觉分隔。
;;;   - 空间不足**不静默夹紧**，而是照常铺（尽量留出可见区域）并输出 size-warning，
;;;     由上层（状态栏 / 提示）显示「空间不足」。
;;;
;;; 已定：
;;;   - 二叉（就 node）：更复杂的多栏以后要再说，先不做。
;;; 待定：
;;;   - size 语义（当前是「第一段的格数」，#f = 均分）。
;;;   - 空间不足时的**兜底铺法**（当前：扣掉 gap 后对半，可能小于 min）。
;;;   - 分割条的交互（拖拽 → tree-resize；当前只铺出 bar + 提供 tree-resize）。

(provide (struct-out leaf)
         (struct-out node)
         (struct-out bar)
         (struct-out size-warning)
         tree? tree-vids tree-contains?
         tree-split tree-remove tree-replace tree-resize tree->rectangles
         min-pane-width min-pane-height split-gap)

(define min-pane-width 4)
(define min-pane-height 1)
(define split-gap 1)                     ; 分割条厚（格）

(struct leaf (vid) #:transparent)
(struct node (dir size a b) #:transparent)
;; dir  : 'lr | 'tb
;; size : nat / #f（#f = 均分）

;; 一条分割条（屏幕矩形）。
(struct bar (dir x y width height) #:transparent)

;; 某个 node 的空间不够放两段（各 >= min）时发出。
(struct size-warning (dir need got) #:transparent)
;; dir : 'lr | 'tb；need : 需要的最小尺寸；got : 实际尺寸

(define (tree? t) (or (leaf? t) (node? t)))

(define (tree-vids t)
  (cond [(leaf? t) (list (leaf-vid t))]
        [else (append (tree-vids (node-a t)) (tree-vids (node-b t)))]))

(define (tree-contains? t vid)
  (cond [(leaf? t) (eqv? (leaf-vid t) vid)]
        [else (or (tree-contains? (node-a t) vid) (tree-contains? (node-b t) vid))]))

;;; ---------- 尺寸 ----------

(define (node-extent dir a) (if (eq? dir 'lr) (area-width a) (area-height a)))
(define (node-min dir) (if (eq? dir 'lr) min-pane-width min-pane-height))

;; 一个 node 正常分两段所需的最小尺寸。
(define (node-need dir) (+ (* 2 (node-min dir)) split-gap))

;; 把第一段尺寸夹到合法区间（两段各 >= mn，中间留 gap）。
(define (clamp-size s e mn gap)
  (define lo (min mn (max 1 (sub1 e))))
  (define hi (max lo (- e gap lo)))
  (max lo (min s hi)))

;; → (values 第一段尺寸 是否放得下)
(define (resolve-size s e mn gap)
  (define need (+ (* 2 mn) gap))
  (cond
    [(>= e need) (values (clamp-size (or s (quotient (- e gap) 2)) e mn gap) #t)]
    [else (values (quotient (max 0 (- e gap)) 2) #f)]))

;;; ---------- 改树 ----------

;; 把 vid 那个 leaf 换成 node(dir, leaf vid, leaf new-vid)；新窗格在右 / 下。
(define (tree-split t vid dir new-vid [size #f])
  (cond
    [(leaf? t) (if (eqv? (leaf-vid t) vid) (node dir size (leaf vid) (leaf new-vid)) t)]
    [else (struct-copy node t
                       [a (tree-split (node-a t) vid dir new-vid size)]
                       [b (tree-split (node-b t) vid dir new-vid size)])]))

;; 把 vid 那个 leaf 换成同位置的 new-vid（不改变结构）。
(define (tree-replace t vid new-vid)
  (cond
    [(leaf? t) (if (eqv? (leaf-vid t) vid) (leaf new-vid) t)]
    [else (struct-copy node t
                       [a (tree-replace (node-a t) vid new-vid)]
                       [b (tree-replace (node-b t) vid new-vid)])]))

;; 删掉 vid 那个 leaf。→ 新树 / #f（空，即删的是最后一个）。
(define (tree-remove t vid)
  (define (prune t)
    (cond
      [(leaf? t) (if (eqv? (leaf-vid t) vid) #f t)]
      [else
       (define a* (prune (node-a t)))
       (define b* (prune (node-b t)))
       (cond [(and a* b*) (struct-copy node t [a a*] [b b*])]
             [a* a*]
             [b* b*]
             [else #f])]))
  (prune t))

;; 沿 vid 所在路径找最近的、方向匹配 axis 的 node，把第一段尺寸调 delta。
(define (tree-resize t vid axis delta area)
  (define target (if (eq? axis 'width) 'lr 'tb))
  (define (go t area)
    (cond
      [(leaf? t) t]
      [else
       (define dir (node-dir t))
       (define e (node-extent dir area))
       (define mn (node-min dir))
       (define-values (s _fits?) (resolve-size (node-size t) e mn split-gap))
       (define in-a? (tree-contains? (node-a t) vid))
       (define in-b? (tree-contains? (node-b t) vid))
       (cond
         [(and (eq? dir target) (or in-a? in-b?))
          (struct-copy node t [size (clamp-size (+ s (if in-a? delta (- delta))) e mn split-gap)])]
         [else
          (define-values (a _bar b) (area-split/gap area dir s split-gap))
          (struct-copy node t
                       [size s]
                       [a (if in-a? (go (node-a t) a) (node-a t))]
                       [b (if in-b? (go (node-b t) b) (node-b t))])])]))
  (go t area))

;;; ---------- 铺进屏幕 ----------

;; → (values (listof rectangle) (listof bar) (listof size-warning))
(define (tree->rectangles t area)
  (define (go t area)
    (cond
      [(leaf? t)
       (values (list (rectangle (leaf-vid t)
                                (area-x area) (area-y area)
                                (area-width area) (area-height area) 0))
               '() '())]
      [else
       (define dir (node-dir t))
       (define e (node-extent dir area))
       (define mn (node-min dir))
       (define-values (s fits?) (resolve-size (node-size t) e mn split-gap))
       ;; 空间极小时 gap 也可以退化成 0，避免出现负宽。
       (define gap (min split-gap (max 0 (sub1 e))))
       (define-values (a b-area c) (area-split/gap area dir s gap))
       (define-values (ra ba wa) (go (node-a t) a))
       (define-values (rc bc wc) (go (node-b t) c))
       (values (append ra rc)
               (cons (bar dir (area-x b-area) (area-y b-area)
                          (area-width b-area) (area-height b-area))
                     (append ba bc))
               (append (if fits? '() (list (size-warning dir (node-need dir) e)))
                       wa wc))]))
  (go t area))

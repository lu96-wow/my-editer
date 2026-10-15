#lang racket

;;; layout/solve.rkt —— 树 → 摆放（纯）
;;;
;;;   tree->panels     : tree area → (listof panel)        core 直接吃
;;;   tree->placements : tree area → (listof (list id rect))
;;;   tree->cuts       : tree area → (listof cut)          缝（拖拽用）
;;;
;;; 同层按 size 权重比例分额度；隐藏跳过（size 保留）。边框不在生产者里决定：
;;; 用 leaf 自己的 borders（默认全边）。窗口 resize 时按权重自动重分。
;;;
;;; area 是外层 rect（屏幕坐标，x=列 y=行）。

(provide (struct-out cut)
         cut-at cuts-at
         tree->panels tree->placements tree->cuts)

(require "tree.rkt"
         "../core/view/panel.rkt"
         "../core/view/base/rect.rkt")

(struct cut (axis offset span-lo span-hi path index before after) #:transparent)
;; axis      'lr（竖缝，offset = 列）| 'tb（横缝，offset = 行）
;; span-lo/hi 缝的纵向 / 横向范围 [lo, hi)
;; path      到所属 split 的「孩子下标」路径；index = 缝左 / 上方的孩子下标
;; before/after 缝两侧孩子当前的格数（拖拽按格数改 size 用）
;; 拖拽：改该 split 第 index / index+1 个孩子的 size（见 tree-resize-at）。

;; 屏幕格 (row, col) 命中哪条缝（缝是 1 格宽/高的线）。
(define (cut-match? c row col)
  (case (cut-axis c)
    [(lr) (and (= col (cut-offset c))
               (<= (cut-span-lo c) row) (< row (cut-span-hi c)))]
    [(tb) (and (= row (cut-offset c))
               (<= (cut-span-lo c) col) (< col (cut-span-hi c)))]))

;; 该点命中的**所有**缝（交点 = 竖缝 + 横缝 → 角拖）。
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
;; 接缝两侧都画自己的边 → 重叠在同一格，由 border-owner（deep/weight/列表序）选一个 face
;; = 一条线。屏幕边（outer）的框由 dock 决定去不去。
;;
;; outer 边集随 rect 下推：非最后孩子把「右(lr)/下(tb)」变成内部，非第一把「左(lr)/上(tb)」变内部。
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

(module+ test
  (require rackunit)
  ;; 直接搭：左 tree(4) ｜ 右 tb[editor(3) / status(1)]
  (define tr
    (split 'lr
           (list (make-leaf 'tree #f #:size 4 #:borders '(right))          ; 左侧 dock：内缝
                 (split 'tb
                        (list (make-leaf 'editor #f #:size 3)                    ; 主区：全边
                              (make-leaf 'status #f #:size 1 #:borders '(up)))   ; 底部 dock：上缝
                        1 #t))
           1 #t))
  (define area (rect 0 0 100 40))

  (define ps (tree->panels tr area))
  (define pls (tree->placements tr area))
  (check-equal? (length ps) 3)
  (define (rect-of id) (cadr (assoc id pls)))
  (define (panel-of id) (cdr (assoc id (map cons (map car pls) ps))))

  ;; 相邻边界重叠：共享 1 格
  (check-equal? (let ([r (rect-of 'tree)]) (list (rect-x r) (rect-y r) (rect-w r) (rect-h r)))
                '(0 0 81 40))
  (check-equal? (rect-x (rect-of 'editor)) (sub1 (rect-right (rect-of 'tree))))   ; 从接缝格开始
  (check-equal? (rect-y (rect-of 'status)) (sub1 (rect-bottom (rect-of 'editor))))
  (check-equal? (rect-x (rect-of 'status)) (rect-x (rect-of 'editor)))

  ;; 有效边框 = 内部边 ∪ (外部边 ∩ 声明)：
  ;;   tree 内缝右；editor 全（内缝左/下 + 外缝上/右）；status 上/左（上缝 + 左接缝）
  (check-equal? (panel-borders (panel-of 'tree)) '(right))
  (check-equal? (panel-borders (panel-of 'editor)) '(up down left right))
  (check-equal? (panel-borders (panel-of 'status)) '(up left))

  ;; cuts：一条竖缝 + 一条横缝
  (define cs (tree->cuts tr area))
  (check-equal? (length cs) 2)
  (check-equal? (sort (map cut-axis cs) symbol<?) '(lr tb))
  ;; cut-at 命中缝
  (define x0 (rect-x (rect-of 'editor)))
  (check-not-false (cut-at cs 5 x0))
  (check-false (cut-at cs 5 (sub1 x0)))
  ;; 交点：cuts-at 两条（竖 + 横）
  (check-equal? (length (cuts-at cs (cut-offset (car (filter (λ (c) (eq? (cut-axis c) 'tb)) cs)))
                                       x0))
                2)

  ;; 隐藏 tree → 右侧占满（无接缝，1 个可见孩子）
  (define pl2 (tree->placements (tree-hide tr 'tree) area))
  (check-equal? (length pl2) 2)
  (check-equal? (let ([r (cadr (assoc 'editor pl2))]) (list (rect-x r) (rect-w r))) '(0 100))
  (check-equal? (let ([r (cadr (assoc 'status pl2))]) (list (rect-x r) (rect-w r))) '(0 100))

  ;; 极端：窗口很窄也不负数
  (define pl3 (tree->placements tr (rect 0 0 1 1)))
  (check-true (for/and ([pl (in-list pl3)]) (>= (rect-w (cadr pl)) 0)))

  (displayln "layout/solve.rkt: ok"))

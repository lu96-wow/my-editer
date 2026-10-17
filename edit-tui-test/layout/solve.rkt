#lang racket

;;; 由 edit-tui/layout/solve.rkt 的测试外移而来（edit-tui 只留实现）。
(require rackunit
         "../../edit-tui/layout/solve.rkt"
         "../../edit-tui/layout/tree.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt")
(define (leaf-size* l) (dim-value (leaf-dim l)))


;; 直接搭：左 tree(4) ｜ 右 tb[editor(3) / status(1)]
(define tr
  (split 'lr
         (list (make-leaf 'tree #f #:size 4 #:borders '(right))          ; 左侧 dock：内缝
               (split 'tb
                      (list (make-leaf 'editor #f #:size 3)                    ; 主区：全边
                            (make-leaf 'status #f #:size 1 #:borders '(up)))   ; 底部 dock：上缝
                      1))
         1))
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

;; 有效边框 = 内部边 ∪ (外部边 ∩ 声明)
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

;; 隐藏中间孩子：缝只连可见邻块；拖缝改的是可见邻块（不是被隐藏那个）
(define flat (split 'lr (list (make-leaf 'a #f #:size 1)
                             (make-leaf 'b #f #:size 1)
                             (make-leaf 'c #f #:size 1))
                   1))
(define flat-h (tree-hide flat 'b))
(define csh (tree->cuts flat-h area))
(check-equal? (length csh) 1)
(define c0 (car csh))
(check-equal? (cut-index c0) 0)
(define flat-r (tree-resize-at flat-h (cut-path c0) (cut-index c0) 5 7))
(check-equal? (map leaf-size* (tree-leaves flat-r)) '(5 1 7))

;; 拖缝按格数：三块可见时也只重分 seam 两侧，第三块比例不受影响（权重 ≠ 格数）
(define flat3 (split 'lr (list (make-leaf 'a #f #:size 4)
                               (make-leaf 'b #f #:size 3)
                               (make-leaf 'c #f #:size 1))
                     1))
(define (width-of t id) (rect-w (cadr (assoc id (tree->placements t area)))))
(define c3 (car (tree->cuts flat3 area)))              ; a|b 缝，index 0
(check-equal? (list (cut-cells-before c3) (cut-cells-after c3)) '(51 38))
(define flat3* (tree-resize-seam flat3 c3 10))         ; 右拖 10 格
(check-true (> (leaf-size* (tree-find flat3* 'a)) 4))
(check-true (< (leaf-size* (tree-find flat3* 'b)) 3))
(check-equal? (leaf-size* (tree-find flat3* 'c)) 1)         ; 第三块权重不变
(check-equal? (width-of flat3* 'c) (width-of flat3 'c))    ; c 格数也不变
(check-true (> (width-of flat3* 'a) (width-of flat3 'a)))
(check-true (< (width-of flat3* 'b) (width-of flat3 'b)))

;; 整棵子树隐藏 → 不占空间（不产生空档）；只剩一个可见孩子
(define tr2 (tree-hide (tree-hide tr 'editor) 'status))
(define pl4 (tree->placements tr2 area))
(check-equal? (length pl4) 1)
(check-equal? (let ([r (cadr (car pl4))]) (list (rect-x r) (rect-w r))) '(0 100))
(check-equal? (tree->cuts tr2 area) '())

;; 极端：窗口很窄也不负数
(define pl3 (tree->placements tr (rect 0 0 1 1)))
(check-true (for/and ([pl (in-list pl3)]) (>= (rect-w (cadr pl)) 0)))

;; ---------- 固定尺寸 / min / max ----------
(define area2 (rect 0 0 60 12))
(define (panel-by t id)
  (define pls (tree->placements t area2))
  (define ps (tree->panels t area2))
  (cdr (assoc id (map cons (map car pls) ps))))
(define (content-h t id) (rect-h (panel-content (panel-by t id))))
(define (content-w t id) (rect-w (panel-content (panel-by t id))))

;; 状态栏固定 1 行内容（末尾孩子：上边框 + 1 内容 → rect 2）
(define tfix (split 'tb (list (make-leaf 'editor #f #:size (flex 1))
                              (make-leaf 'slot #f #:size (fixed 1) #:borders '()))
                    (flex 1)))
(check-equal? (content-h tfix 'slot) 1)

;; 抽屉在状态栏之后：状态栏变中间孩子（上下边框）仍是 1 行内容；抽屉固定 2 行内容
(define tdrawer (split 'tb (list (make-leaf 'editor #f #:size (flex 1))
                                 (make-leaf 'slot #f #:size (fixed 1) #:borders '())
                                 (make-leaf 'drawer #f #:size (fixed 2)))
                       (flex 1)))
(check-equal? (content-h tdrawer 'slot) 1)
(check-equal? (content-h tdrawer 'drawer) 2)

;; flex max：侧栏内容不超过 10（内容 max，solver 自动加边框厚度）
(define tmax (split 'lr (list (make-leaf 'side #f #:size (flex 1 #:max 10))
                              (make-leaf 'editor #f #:size (flex 1)))
                    (flex 1)))
(check-equal? (content-w tmax 'side) 10)

;; flex min：窄屏下侧栏至少 5 内容（编辑器 flex 吸收）
(define tmin (split 'lr (list (make-leaf 'side #f #:size (flex 1 #:min 5))
                              (make-leaf 'editor #f #:size (flex 1)))
                    (flex 1)))
(define area-narrow (rect 0 0 12 12))
(define (content-w* t area id)
  (define pls (tree->placements t area)) (define ps (tree->panels t area))
  (rect-w (panel-content (cdr (assoc id (map cons (map car pls) ps))))))
(define w-min (content-w* tmin area-narrow 'side))
(check-true (>= w-min 5))

;; 没有 flex 时余量给第一个孩子（末尾固定面板贴底）
(define tnoflex (split 'tb (list (make-leaf 'top #f #:size (fixed 2))
                                 (make-leaf 'bot #f #:size (fixed 1)))
                       (flex 1)))
(define plnoflex (tree->placements tnoflex area2))
(define botr (cadr (assoc 'bot plnoflex)))
(check-equal? (+ (rect-y botr) (rect-h botr)) 12)   ; bot 贴底

(displayln "edit-tui/layout/solve.rkt: ok")


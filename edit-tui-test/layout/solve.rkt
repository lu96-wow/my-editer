#lang racket

;;; 由 edit-tui/layout/solve.rkt 的测试外移而来（edit-tui 只留实现）。
(require rackunit
         "../../edit-tui/layout/solve.rkt"
         "../../edit-tui/layout/tree.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt")

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
(check-equal? (map leaf-size (tree-leaves flat-r)) '(5 1 7))

;; 整棵子树隐藏 → 不占空间（不产生空档）；只剩一个可见孩子
(define tr2 (tree-hide (tree-hide tr 'editor) 'status))
(define pl4 (tree->placements tr2 area))
(check-equal? (length pl4) 1)
(check-equal? (let ([r (cadr (car pl4))]) (list (rect-x r) (rect-w r))) '(0 100))
(check-equal? (tree->cuts tr2 area) '())

;; 极端：窗口很窄也不负数
(define pl3 (tree->placements tr (rect 0 0 1 1)))
(check-true (for/and ([pl (in-list pl3)]) (>= (rect-w (cadr pl)) 0)))

(displayln "edit-tui/layout/solve.rkt: ok")

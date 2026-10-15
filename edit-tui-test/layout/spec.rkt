#lang racket

;;; 由 edit-tui/layout/spec.rkt 的测试外移而来（edit-tui 只留实现）。
(require rackunit
         "../../edit-tui/layout/spec.rkt"
         "../../edit-tui/layout/tree.rkt")

(check-equal? (dock-borders 'left) '(right))
(check-equal? (dock-borders 'top) '(down))
(check-equal? (dock-borders 'bottom) '(up))
(check-equal? (dock-borders 'right) '(left))
(check-equal? (dock-borders 'center) '(up down left right))
(check-equal? (dock-borders #f) '(up down left right))

(define t (lay 'lr
             (pane 'tree #:view 'tv #:size 4 #:dock 'left)
             (lay 'tb
                  (pane 'editor #:view 'ev #:size 3 #:dock 'center)
                  (pane 'status #:view #f #:size 1 #:dock 'bottom))))
(check-true (split? t))
(check-equal? (map leaf-id (tree-leaves t)) '(tree editor status))
(check-equal? (leaf-borders (tree-find t 'tree)) '(right))
(check-equal? (leaf-borders (tree-find t 'editor)) '(up down left right))
(check-equal? (leaf-borders (tree-find t 'status)) '(up))
(check-equal? (leaf-size (tree-find t 'tree)) 4)
;; #:borders 覆盖 dock；pane 直接产出 leaf
(define t2 (pane 'x #:view #f #:dock 'left #:borders '(down)))
(check-true (leaf? t2))
(check-equal? (leaf-borders t2) '(down))

(displayln "edit-tui/layout/spec.rkt: ok")

#lang racket

;;; 由 edit-tui/layout/tree.rkt 的测试外移而来（edit-tui 只留实现）。
(require rackunit
         "../../edit-tui/layout/tree.rkt")

(define t1 (tree-split (make-leaf 'editor #f) 'editor 'lr 'tree #:side 'before))
(define (ids t) (map leaf-id (tree-leaves t)))

;; 结构
(check-true (leaf? (tree-find t1 'editor)))
(check-equal? (ids t1) '(tree editor))
(check-true (tree-contains? t1 'tree))
(check-false (tree-contains? t1 'nope))

;; 同轴再插：n 叉，不加深
(define t2 (tree-split t1 'editor 'lr 'status #:side 'after))
(check-equal? (ids t2) '(tree editor status))
(check-equal? (split-axis t2) 'lr)
(check-equal? (length (split-children t2)) 3)

;; 异轴插：嵌套
(define t3 (tree-split t2 'editor 'tb 'console #:side 'after))
(check-equal? (ids t3) '(tree editor console status))

;; 关闭：删叶子 + 单孩子 split 塌缩
(define t4 (tree-close t3 'editor))
(check-equal? (ids t4) '(tree console status))

;; 塌缩要继承子树 size：拆开再关掉一个，剩下的应拿回整棵子树的额度（否则高度缩水）
(define tz1 (tree-split (make-leaf 'a #f #:size 8) 'a 'lr 'b #:side 'after))
(check-equal? (leaf-size (tree-find tz1 'a)) 1)
(define tz2 (tree-close tz1 'b))
(check-equal? (leaf-size (tree-find tz2 'a)) 8)

;; 摘除
(define-values (t5 removed) (tree-detach t3 'status))
(check-equal? (ids t5) '(tree editor console))
(check-true (leaf? removed))
(check-eq? (leaf-id removed) 'status)

;; 移动：tree 挪到 editor 旁边（tb 同轴插入）
(define t6 (tree-move t3 'tree 'editor 'tb #:side 'after))
(check-equal? (ids t6) '(editor tree console status))

;; 移动：目标不存在 / 目标是自己 → 原样返回，不丢节点
(check-equal? (ids (tree-move t3 'tree 'nope 'lr)) (ids t3))
(check-equal? (ids (tree-move t3 'tree 'tree 'lr)) (ids t3))

;; 显隐：隐藏保留 size，恢复回来
(define t7 (tree-hide t2 'tree))
(check-false (tree-visible? t7 'tree))
(check-equal? (leaf-size (tree-find t7 'tree)) (leaf-size (tree-find t2 'tree)))
(check-equal? (map leaf-id (tree-visible-leaves t7)) '(editor status))
(check-equal? (ids (tree-show t7 'tree)) '(tree editor status))

;; 改字段
(check-equal? (leaf-view (tree-find (tree-set-view t2 'tree 'v) 'tree)) 'v)
(check-equal? (leaf-weight (tree-find (tree-set-weight t2 'tree 9) 'tree)) 9)
(check-false (leaf-visible? (tree-find (tree-set-visible t2 'tree #f) 'tree)))
(check-true (leaf-visible? (tree-find (tree-set-visible (tree-hide t2 'tree) 'tree #t) 'tree)))

;; 拖缝：按路径改两个相邻可见孩子的 size
(define t8 (tree-resize-at t2 '() 0 5 7))
(check-equal? (leaf-size (tree-find t8 'tree)) 5)
(check-equal? (leaf-size (tree-find t8 'editor)) 7)
;; 中间夹隐藏孩子时，伙伴取下一个**可见**孩子（不是 index+1）
(define t2h (tree-hide t2 'editor))
(check-equal? (map leaf-id (tree-visible-leaves t2h)) '(tree status))
(define t9 (tree-resize-at t2h '() 0 5 7))
(check-equal? (leaf-size (tree-find t9 'tree)) 5)
(check-equal? (leaf-size (tree-find t9 'status)) 7)      ; 跳到 status
(check-equal? (leaf-size (tree-find t9 'editor)) 1)      ; 隐藏的没被动

(displayln "edit-tui/layout/tree.rkt: ok")

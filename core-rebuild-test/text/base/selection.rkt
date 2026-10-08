#lang racket

;; 由 core/text/base/selection.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core-rebuild/text/base/selection.rkt"
       "../../../core-rebuild/text/base/point.rkt")

(define (p l c) (point l c))

(check-true (selection-empty? (caret (p 0 0))))
(check-true (caret? (caret (p 0 3))))
(check-false (caret? (selection (p 0 0) (p 0 3))))
(check-equal? (selection-point (selection (p 0 0) (p 0 3))) (p 0 3))
(check-equal? (selection-point (caret (p 1 2))) (p 1 2))

(check-equal? (call-with-values (lambda () (selection-range (selection (p 1 2) (p 0 1)))) list)
              (list (p 0 1) (p 1 2)))
(check-equal? (selection-normalize (selection (p 1 2) (p 0 1))) (selection (p 0 1) (p 1 2)))

;; 普通方向键：坍缩到 head 再移动
(check-equal? (selection-go (selection (p 0 0) (p 0 2)) (lambda (x) (p 0 3)))
              (caret (p 0 3)))
;; Shift：只动 head
(check-equal? (selection-extend (selection (p 0 0) (p 0 2)) (lambda (x) (p 0 5)))
              (selection (p 0 0) (p 0 5)))
;; map 端点
(check-equal? (selection-map-anchor (lambda (x) (p 9 9)) (selection (p 0 1) (p 0 2)))
              (selection (p 9 9) (p 0 2)))
(check-equal? (selection-map-both (lambda (x) (point (point-line x) (+ 10 (point-column x))))
                                  (selection (p 0 1) (p 0 2)))
              (selection (p 0 11) (p 0 12)))

;; --- 选区集（多光标） ---
(define ss (selections-of (list (caret (p 0 0)) (caret (p 0 3))) 1))
(check-equal? (selections-count ss) 2)
(check-equal? (selections-primary ss) (caret (p 0 3)))
(check-equal? (selections-primary (selections-add ss (list (caret (p 0 5)))))
              (caret (p 0 3)))                       ; 追加不改 primary
(check-equal? (selections-count (selections-remove ss (list (caret (p 0 0))))) 1)
(check-equal? (selections-primary (selections-set-primary ss 0)) (caret (p 0 0)))
(check-equal? (selections-primary (selections-set-primary-value ss (caret (p 0 0))))
              (caret (p 0 0)))

;; 普通方向键：全部坍缩+移动，碰撞去重
(check-equal? (selections-items (selections-go ss (lambda (x) (p 1 0))))
              (list (caret (p 1 0))))
;; Shift：扩选
(check-equal? (selections-items (selections-extend (selections-one (caret (p 0 1)))
                                                  (lambda (x) (p 0 4))))
              (list (selection (p 0 1) (p 0 4))))
;; 只动 primary
(check-equal? (selections-items (selections-go-primary ss (lambda (x) (p 9 9))))
              (list (caret (p 0 0)) (caret (p 9 9))))

;; 去重
(check-equal? (selections-count
               (selections-dedupe (selections-of (list (caret (p 0 0)) (caret (p 0 0))) 1)))
              1)

;; 归一：重叠合并，primary 追到包络
(define sn (selections-normalize
            (selections-of (list (selection (p 0 0) (p 0 4)) (selection (p 0 2) (p 0 6))) 1)))
(check-equal? (selections-count sn) 1)
(check-equal? (selections-primary sn) (selection (p 0 0) (p 0 6)))
;; 首尾相接不合并
(check-equal? (selections-count
               (selections-normalize
                (selections-of (list (selection (p 0 0) (p 0 2)) (selection (p 0 2) (p 0 4))) 1)))
              2)
;; 边界不歧义：[0,2) 与 caret(2) 并存时 primary=caret
(check-equal? (selections-primary
               (selections-normalize
                (selections-of (list (selection (p 0 0) (p 0 2)) (caret (p 0 2))) 1)))
              (caret (p 0 2)))

;; selections-clamp：把每个选区两端夹进合法域
(check-equal? (selections-items (selections-clamp (selections-one (caret (p 9 9))) 3 (lambda (l) 4)))
              (list (caret (p 2 4))))
(check-equal? (selections-items (selections-clamp (selections-one (selection (p 9 9) (p -1 -1))) 3 (lambda (l) 4)))
              (list (selection (p 2 4) (p 0 0))))

(displayln "selection.rkt: all tests passed")

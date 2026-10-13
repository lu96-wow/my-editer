#lang racket

;; 与 core/text/base/change.rkt / range.rkt 对应的外部测试。
(require rackunit
         "../../../core/text/base/change.rkt"
         "../../../core/text/base/range.rkt"
         "../../../core/text/base/point.rkt")

(define (p l c) (point l c))
(define (r a b) (range a b))

;; ---------- range：构造归一 / 判空 ----------
(check-true (range=? (range-of (p 1 2) (p 0 0)) (r (p 0 0) (p 1 2))))
(check-true (range-empty? (r (p 0 0) (p 0 0))))
(check-false (range-empty? (r (p 0 0) (p 0 1))))

;; ---------- change-kind / empty ----------
(define ins (change (r (p 0 1) (p 0 1)) (r (p 0 1) (p 0 3))))          ; 在 (0,1) 插 "XX"
(check-equal? (change-kind ins) 'insert)
(check-equal? (change-kind (change (r (p 0 1) (p 0 3)) (r (p 0 1) (p 0 1)))) 'delete)
(check-equal? (change-kind (change (r (p 0 1) (p 0 3)) (r (p 0 1) (p 0 4)))) 'replace)
(check-equal? (change-kind (change (r (p 0 1) (p 0 1)) (r (p 0 1) (p 0 1)))) 'none)
(check-true (change-empty? (change (r (p 0 1) (p 0 1)) (r (p 0 1) (p 0 1)))))
(check-false (change-empty? ins))
(check-equal? (change-post-range ins) (r (p 0 1) (p 0 3)))          ; 当前坐标脏区 = after

;; ---------- change-map-point ----------
;; 插入：≤ start 不动；之后整体平移
(check-equal? (change-map-point ins (p 0 0)) (p 0 0))
(check-equal? (change-map-point ins (p 0 1)) (p 0 1))
(check-equal? (change-map-point ins (p 0 2)) (p 0 4))
(check-equal? (change-map-point ins (p 1 3)) (p 1 3))

;; 删除 (0,1)-(0,3)：区间内部 → #f；之后左移
(define del (change (r (p 0 1) (p 0 3)) (r (p 0 1) (p 0 1))))
(check-equal? (change-map-point del (p 0 1)) (p 0 1))
(check-false (change-map-point del (p 0 2)))
(check-equal? (change-map-point del (p 0 4)) (p 0 2))

;; 跨行替换 before ((0,1)-(2,1)) → after ((0,1)-(1,2))：Δline = -1
(define rep (change (r (p 0 1) (p 2 1)) (r (p 0 1) (p 1 2))))
(check-equal? (change-map-point rep (p 0 1)) (p 0 1))
(check-equal? (change-map-point rep (p 2 1)) (p 1 2))
(check-equal? (change-map-point rep (p 2 4)) (p 1 5))
(check-equal? (change-map-point rep (p 5 0)) (p 4 0))

;; ---------- changes-map-point：多条（从右往左）/ 前进 vs 字面 ----------
(define two (list (change (r (p 0 0) (p 0 0)) (r (p 0 0) (p 0 5)))    ; (0,0) 插 "XXXXX"
                  (change (r (p 0 5) (p 0 5)) (r (p 0 5) (p 0 6)))))  ; (0,5) 插 "Y"
(check-equal? (changes-map-point two (p 0 4)) (p 0 9))               ; 只受左侧插入影响
(check-equal? (changes-map-point two (p 0 5)) (p 0 11))              ; 自己的零宽插入 → 前进
(check-equal? (changes-map-point-literal two (p 0 5)) (p 0 10))      ; 字面不动

(displayln "change.rkt: all tests passed")

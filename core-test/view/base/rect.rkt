#lang racket

;;; core/view/base/rect.rkt —— 矩形几何（内缩 / 包含边界）。
(require rackunit
         "../../../core/view/base/rect.rkt")

(define r (rect 2 3 5 4))
(check-equal? (rect-right r) 7)
(check-equal? (rect-bottom r) 7)

;; 内缩；宽高不足时夹到 0，不产生负尺寸
(check-equal? (rect-inset r 1) (rect 3 4 3 2))
(check-equal? (rect-inset r 10) (rect 12 13 0 0))
;; 每边独立（top right bottom left）
(check-equal? (rect-inset-sides r 1 2 3 4) (rect 6 4 0 0))
(check-equal? (rect-inset-sides r 0 0 0 0) r)

;; 包含：左闭右开
(check-true (rect-contains? r 2 3))     ; 左上角
(check-true (rect-contains? r 6 6))     ; 右下前一格
(check-false (rect-contains? r 7 3))    ; 右边
(check-false (rect-contains? r 2 7))    ; 下边
(check-false (rect-contains? r 1 3))
(check-false (rect-contains? r 2 2))
(check-false (rect-contains? (rect 1 1 0 0) 1 1))   ; 零尺寸不含点

(displayln "view/base/rect.rkt: ok")

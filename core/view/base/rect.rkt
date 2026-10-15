#lang racket

;;; core/view/base/rect.rkt —— 矩形 + 算术（几何值）
;;;
;;; 边框 / 内容区唯一用到的几何值。布局树在 core 外（切分 / 树是 panels 的生产者），
;;; core 只吃已定位的 panel，里面带的 rect 就是它。

(provide (struct-out rect)
         rect-right rect-bottom
         rect-inset rect-inset-sides
         rect-contains?)

(struct rect (x y w h) #:transparent)

(define (rect-right r) (+ (rect-x r) (rect-w r)))
(define (rect-bottom r) (+ (rect-y r) (rect-h r)))

;; 四周各内缩 n。
(define (rect-inset r n) (rect-inset-sides r n n n n))

;; 每边独立内缩：top right bottom left。
(define (rect-inset-sides r top right bottom left)
  (rect (+ (rect-x r) left)
        (+ (rect-y r) top)
        (max 0 (- (rect-w r) left right))
        (max 0 (- (rect-h r) top bottom))))

;; 左闭右开：x ∈ [x, x+w)，y ∈ [y, y+h)。
(define (rect-contains? r x y)
  (and (<= (rect-x r) x) (< x (rect-right r))
       (<= (rect-y r) y) (< y (rect-bottom r))))

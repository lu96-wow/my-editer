#lang racket

;;; edit4/layout/rect.rkt —— 矩形（布局层唯一的几何值）
;;;
;;; 布局层只认矩形与不透明 id；不认识 vid / document / face / plugin。
;;; （浮窗那 1 格“框”只是一圈内容内缩的几何约定，见 float.rkt；字形/face 在 view。）

(provide (struct-out rect) rect-right rect-bottom rect-contains? rect-bounds)

(struct rect (x y w h) #:transparent)

(define (rect-right r) (+ (rect-x r) (rect-w r)))
(define (rect-bottom r) (+ (rect-y r) (rect-h r)))

;; 半开区间：右/下边界不含。
(define (rect-contains? r x y)
  (and (<= (rect-x r) x) (< x (rect-right r))
       (<= (rect-y r) y) (< y (rect-bottom r))))

;; 一组矩形的包围盒（空 → #f）。用 apply 保持精确整数。
(define (rect-bounds rs)
  (cond
    [(null? rs) #f]
    [else
     (define x0 (apply min (map rect-x rs)))
     (define y0 (apply min (map rect-y rs)))
     (define x1 (apply max (map rect-right rs)))
     (define y1 (apply max (map rect-bottom rs)))
     (rect x0 y0 (- x1 x0) (- y1 y0))]))

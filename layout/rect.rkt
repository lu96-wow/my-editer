#lang racket

;;; edit/layout/rect.rkt —— 矩形 + 算术（布局唯一几何值）

(provide (struct-out rect)
         rect-right rect-bottom
         rect-inset rect-inset-sides
         rect-split
         rect-contains?)

(struct rect (x y w h) #:transparent)

(define (rect-right r) (+ (rect-x r) (rect-w r)))
(define (rect-bottom r) (+ (rect-y r) (rect-h r)))

;; 四周各内缩 n（内容区常用 1，因为边框占 1 格）。
(define (rect-inset r n) (rect-inset-sides r n n n n))

;; 每边独立内缩：top right bottom left。
(define (rect-inset-sides r top right bottom left)
  (rect (+ (rect-x r) left)
        (+ (rect-y r) top)
        (max 0 (- (rect-w r) left right))
        (max 0 (- (rect-h r) top bottom))))

(define (rect-contains? r x y)
  (and (<= (rect-x r) x) (< x (rect-right r))
       (<= (rect-y r) y) (< y (rect-bottom r))))

;; 拆成两块：axis 'h（左右）时 at = 左边宽；'v（上下）时 at = 上边高；gap = 中间留缝。
(define (rect-split r axis at [gap 0])
  (define at* (max 0 at))
  (case axis
    [(h) (values (rect (rect-x r) (rect-y r) at* (rect-h r))
                 (rect (+ (rect-x r) at* gap) (rect-y r)
                       (max 0 (- (rect-w r) at* gap)) (rect-h r)))]
    [(v) (values (rect (rect-x r) (rect-y r) (rect-w r) at*)
                 (rect (rect-x r) (+ (rect-y r) at* gap)
                       (rect-w r) (max 0 (- (rect-h r) at* gap))))]
    [else (error 'rect-split "axis 必须是 'h / 'v，得到 ~a" axis)]))

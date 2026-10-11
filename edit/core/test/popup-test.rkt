#lang racket

;;; edit-rebuild/core/test/popup-test.rkt —— 浮层尺寸 / 落位几何（纯）
;;;
;;;   raco test edit-rebuild/core/test/popup-test.rkt
;;;
;;; 核心硬约束：弹窗矩形 [y, y+h) 与锚点行 r 不相交（不遮住正在输入的那行）。

(require rackunit
         "../geometry/popup.rkt")

;; 矩形完全不覆盖锚点行。
(define (no-overlap? r y h)
  (or (>= y (add1 r)) (<= (+ y h) r)))

;; 遍历屏幕 / 锚点行 / 期望高度，断言硬约束与钳制。
(for* ([sh (in-list '(1 2 5 10 24 40))]
       [r (in-range sh)]
       [want-h (in-list '(0 1 3 10 100))])
  (define-values (x y w h) (popup-rect r 3 20 want-h 80 sh))
  (check-true (no-overlap? r y h)
              (format "overlap: r=~a sh=~a want-h=~a → y=~a h=~a" r sh want-h y h))
  (check-true (<= (+ x w) 80) "右边缘越界")
  (check-true (<= h (popup-max-h r sh)) "高度超过可用空间")
  (check-true (= w 20) "宽度未按 want-w"))

;; 下方放得下 → 贴锚点下一行
(let-values ([(x y w h) (popup-rect 5 0 10 3 80 24)])
  (check-equal? y 6)
  (check-equal? h 3))

;; 下方放不下、上方够 → 贴锚点上一行（底边 = 锚点行）
(let-values ([(x y w h) (popup-rect 22 0 10 5 80 24)])   ; below=1, above=22
  (check-equal? h 5)
  (check-equal? (+ y h) 22))

;; 两侧都不够 → 高度钳到较大一侧（below=22 > above=1），仍不遮挡
(let-values ([(x y w h) (popup-rect 1 0 10 100 80 24)])
  (check-equal? h 22)
  (check-equal? y 2))

;; 水平：左对齐锚点列，右边缘钳到屏内
(let-values ([(x y w h) (popup-rect 5 78 30 3 80 24)])
  (check-equal? x 50))
(let-values ([(x y w h) (popup-rect 5 0 30 3 80 24)])
  (check-equal? x 0))

;; 宽超过屏宽 → 钳到屏宽
(let-values ([(x y w h) (popup-rect 5 0 200 3 80 24)])
  (check-equal? w 80)
  (check-equal? x 0))

;; popup-window：居中 + 两端夹取
(let-values ([(start rows) (popup-window 100 50 10)])
  (check-equal? rows 10) (check-equal? start 45))
(let-values ([(start rows) (popup-window 100 0 10)])
  (check-equal? start 0))
(let-values ([(start rows) (popup-window 100 99 10)])
  (check-equal? start 90))
(let-values ([(start rows) (popup-window 3 0 10)])
  (check-equal? rows 3) (check-equal? start 0))


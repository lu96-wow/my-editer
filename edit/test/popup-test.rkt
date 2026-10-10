#lang racket

;;; edit/test/popup-test.rkt —— 浮层尺寸 / 落位几何（纯）
;;;
;;;   raco test edit/test/popup-test.rkt
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

;;; ---------- 次窗避让主窗 ----------

(define (rect-overlap? ax ay aw ah bx by bw bh)
  (and (< ax (+ bx bw)) (< bx (+ ax aw))
       (< ay (+ by bh)) (< by (+ ay ah))))

;; 泛化：任意锚点 / 屏幕，主窗 + 次窗都不遮锚点行、互不重叠
(for* ([sh (in-list '(5 10 24 40))]
       [r (in-range sh)]
       [h1 (in-list '(1 3 6 12))])
  (define-values (ax ay aw ah) (popup-rect r 5 20 h1 80 sh))
  (define-values (bx by bw bh) (popup-rect-avoiding r 5 30 6 80 sh ax ay aw ah))
  (check-true (no-overlap? r ay ah) "主窗遮住锚点行")
  (check-true (no-overlap? r by bh) "次窗遮住锚点行")
  (check-false (rect-overlap? ax ay aw ah bx by bw bh) "两窗重叠")
  (check-true (<= (+ bx bw) 80) "次窗右边缘越界"))

;; 主窗在下方 → 次窗优先放锚点上方（底边 = 锚点行）
(let-values ([(ax ay aw ah) (popup-rect 10 5 20 3 80 30)])
  (check-equal? ay 11)
  (let-values ([(bx by bw bh) (popup-rect-avoiding 10 5 30 4 80 30 ax ay aw ah)])
    (check-equal? by 6)
    (check-equal? bh 4)))

;; 锚点上方不够 → 贴主窗下方堆叠
(let-values ([(ax ay aw ah) (popup-rect 2 5 20 3 80 10)])   ; above=2, below=7
  (check-equal? ay 3)
  (let-values ([(bx by bw bh) (popup-rect-avoiding 2 5 30 5 80 10 ax ay aw ah)])
    (check-equal? by 6)                                      ; ay+ah=6
    (check-equal? bh 4)))                                    ; 10-6=4

;; 主窗在上方 → 次窗优先放锚点下方
(let-values ([(ax ay aw ah) (popup-rect 25 5 20 6 80 30)])  ; below=4 <6 → 上方
  (check-equal? (+ ay ah) 25)
  (let-values ([(bx by bw bh) (popup-rect-avoiding 25 5 30 3 80 30 ax ay aw ah)])
    (check-equal? by 26)
    (check-equal? bh 3)))

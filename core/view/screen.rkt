#lang racket

(require rackunit)

;;; screen.rkt —— 后端无关的屏幕帧缓冲
;;;
;;; 屏幕 = 每个显示行一组 run：同 face 的连续文本段。
;;; 宽字符不做特殊处理——run.text 就是原字符，col 是显示列（0-based），
;;; 终端/GUI 自己负责把宽字符显示成 2 列。
;;;
;;; 后端（tui/gui/web）只负责把 screen 画出来；screen 之前的层与后端无关。

(provide
 (struct-out run)
 (struct-out screen)
 make-screen
 screen-diff-rows
 screen-compose)

(struct run (col text face) #:transparent)
;; col  : 显示列（0-based，已按宽字符换算）
;; text : 文本（不含换行）
;; face : 语义 face（immutable hash）

(struct screen (rows cols row-runs cursor-row cursor-col) #:transparent)
;; row-runs   : (vectorof (listof run))  每行的 run 列表（按 col 升序）
;; cursor-row : 显示行（0-based，相对屏幕顶；越界 = 后端不画光标）
;; cursor-col : 显示列（0-based）

(define (make-screen rows cols)
  (screen rows cols (make-vector rows '()) 0 0))

;; 两屏（同尺寸）之间发生变化的行号：(listof row)。
;; 供增量绘制：后端只重画这些行（先清行再画）。
(define (screen-diff-rows old new)
  (for/list ([row (in-range (screen-rows new))]
             #:unless (equal? (vector-ref (screen-row-runs old) row)
                              (vector-ref (screen-row-runs new) row)))
    row))

;; 拼帧：把若干块 (list window-id x y screen) 贴到一张 (rows cols) 大屏。
;; 每块的 runs 按 x 平移（裁剪在 frame 布局层保证不越界，这里也兜底），
;; 只透出 active-id 块的光标（平移后坐标）。后端无关：tui/gui/web 只见一张合成屏。
(define (screen-compose rows cols pieces active-id)
  (define row-runs (make-vector rows '()))
  (for ([piece (in-list pieces)])
    (match-define (list id x y s) piece)
    (for ([r (in-range (screen-rows s))])
      (define dst (+ y r))
      (when (and (>= dst 0) (< dst rows))
        (define shifted
          (for/list ([rn (in-list (vector-ref (screen-row-runs s) r))])
            (run (+ x (run-col rn)) (run-text rn) (run-face rn))))
        (vector-set! row-runs dst (append (vector-ref row-runs dst) shifted)))))
  (define sorted
    (for/vector ([runs (in-vector row-runs)])
      (sort runs (lambda (a b) (< (run-col a) (run-col b))))))
  (define active-piece
    (for/first ([piece (in-list pieces)] #:when (eq? (car piece) active-id)) piece))
  (define-values (cr cc)
    (cond
      [(not active-piece) (values -1 -1)]
      [else
       (match-define (list _ x y s) active-piece)
       (if (>= (screen-cursor-row s) 0)
           (values (+ y (screen-cursor-row s)) (+ x (screen-cursor-col s)))
           (values -1 -1))]))
  (screen rows cols sorted cr cc))

(module+ test
  (define s0 (make-screen 2 10))
  (check-equal? (screen-rows s0) 2)
  (check-equal? (screen-cols s0) 10)
  (check-equal? (vector-length (screen-row-runs s0)) 2)
  (check-equal? (screen-cursor-row s0) 0)
  (check-equal? (screen-cursor-col s0) 0)

  ;; 构造带 run 的屏幕
  (define r1 (run 0 "ab" (hash 'face 'bold)))
  (define r2 (run 2 "中" (hash 'face 'keyword)))
  (define s1 (screen 2 10 (vector (list r1 r2) '()) 0 3))
  (check-equal? (vector-ref (screen-row-runs s1) 0) (list r1 r2))
  (check-equal? (screen-cursor-col s1) 3)

  ;; diff：变化行的行号会被挑出来
  (define s2 (screen 2 10 (vector (list r1 (run 2 "文" (hash 'face 'keyword))) '()) 0 3))
  (check-equal? (screen-diff-rows s1 s2) '(0))
  (check-equal? (screen-diff-rows s1 s1) '())

  ;; screen-compose：两块拼成一帧，active 光标平移
  (define sa (screen 2 4 (vector (list (run 0 "ab" (hash))) (list (run 0 "cd" (hash)))) 1 1))
  (define sb (screen 2 4 (vector (list (run 0 "XY" (hash))) (list (run 0 "ZW" (hash)))) 0 0))
  (define comp (screen-compose 2 8 (list (list 'a 0 0 sa) (list 'b 4 0 sb)) 'b))
  (check-equal? (vector-ref (screen-row-runs comp) 0)
                (list (run 0 "ab" (hash)) (run 4 "XY" (hash))))
  (check-equal? (vector-ref (screen-row-runs comp) 1)
                (list (run 0 "cd" (hash)) (run 4 "ZW" (hash))))
  (check-equal? (screen-cursor-row comp) 0)
  (check-equal? (screen-cursor-col comp) 4)
  ;; active 不在 pieces 里 → 隐藏光标
  (check-equal? (screen-cursor-row (screen-compose 2 8 (list (list 'a 0 0 sa)) 'b)) -1)

  (displayln "screen.rkt: all tests passed"))

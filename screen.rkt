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
 screen-diff)

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

;; 两屏（同尺寸）之间的差异 run：(listof (list row run))。
;; 简单实现：返回新屏中「与旧屏不同 / 新增」的 run，供增量绘制。
(define (screen-diff old new)
  (for*/list ([row (in-range (screen-rows new))]
              [r (in-list (vector-ref (screen-row-runs new) row))]
              #:unless (member r (vector-ref (screen-row-runs old) row)))
    (list row r)))

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

  ;; diff：变化的 run 会被挑出来
  (define s2 (screen 2 10 (vector (list r1 (run 2 "文" (hash 'face 'keyword))) '()) 0 3))
  (define d (screen-diff s1 s2))
  (check-equal? (length d) 1)
  (check-equal? (caar d) 0)                       ; 第 0 行
  (check-equal? (run-text (cadar d)) "文")

  (displayln "screen.rkt: all tests passed"))

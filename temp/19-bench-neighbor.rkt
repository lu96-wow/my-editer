#lang racket
;;; 19 —— panel 方向导航 / 深度前后 的开销
;;;
;;; 运行：racket temp/19-bench-neighbor.rkt
;;;
;;; 两者都是「每次按键一次」的精确查询，不是每帧：
;;;   一遍线性扫描（deep 过滤 / 方向过滤都在同一遍），O(N)，无排序、无候选表。
;;; 这里给出 N（面板数）从 8 到 100000 的每次调用毫秒数。
;;;
;;; 对比：渲染路径 compose 的 O(W×H) owner 网格才是每帧的大头，与这里无关。

(require "../core/view/panel.rkt"
         "../core/view/base/rect.rkt")

(define (ms-per-call iters thunk)
  (define t0 (current-inexact-milliseconds))
  (for ([_ (in-range iters)]) (thunk))
  (/ (- (current-inexact-milliseconds) t0) iters))

;; N 块并排平铺（同层），用于 panel-neighbor 的最坏扫描。
(define (mk-row n)
  (for/list ([i (in-range n)]) (make-panel i (rect (* i 10) 0 10 10) borders-none)))

;; N 块完全重叠、deep 递增，用于 panel-depth-neighbor 的最坏扫描。
(define (mk-stack n)
  (for/list ([i (in-range n)]) (make-panel i (rect 0 0 10 10) borders-none #:deep i)))

(printf "N\tdir/right ms\tdepth/front ms\n")
(for ([n (in-list '(8 100 1000 10000 100000))])
  (define row (mk-row n))
  (define stk (mk-stack n))
  (define iters (max 100 (quotient 2000000 n)))
  (define a (ms-per-call iters (λ () (panel-neighbor row (car row) 'right))))
  (define b (ms-per-call iters (λ () (panel-depth-neighbor stk (car stk) 'front))))
  (printf "~a\t~a\t~a\n" n (real->decimal-string a 5) (real->decimal-string b 5)))

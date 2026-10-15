#lang racket
;;; 15 —— core-rebuild 渲染热点拆分
(require "../core-rebuild/editor.rkt"
         "../core-rebuild/view/patch.rkt"
         "../core-rebuild/view/compose.rkt")

(define (ms) (current-inexact-milliseconds))
(define (bench label n thunk)
  (thunk)
  (define t0 (ms))
  (for ([i (in-range n)]) (thunk))
  (printf "  ~a: ~a ms\n" label (exact->inexact (/ (- (ms) t0) n))))

(define (lines n)
  (string-join (for/list ([i (in-range n)]) (format "~a: (define x~a (+ 1 2 3)) ;; comment" i i)) "\n"))

(for ([wh (list (cons 240 70) (cons 400 120))])
  (define W (car wh)) (define H (cdr wh))
  (printf "==== ~ax~a ====\n" W H)
  (define b1 (make-buffer (lines 3000) "tree"))
  (define b2 (make-buffer (lines 3000) "doc"))
  (define b3 (make-buffer "float\n" "float"))
  (define q (quotient W 4)) (define fw (quotient W 3)) (define fh (max 4 (quotient H 3)))
  (define fx (quotient W 3)) (define fy (quotient H 5))
  (define p1 (buffer-add-panel! b1 (rect 0 0 q H) borders-all #:line-numbers? #t))
  (define p2 (buffer-add-panel! b2 (rect q 0 (- W q) H) '(up down right) #:line-numbers? #t))
  (define p3 (buffer-add-panel! b3 (rect fx fy fw fh) borders-all #:deep 10 #:face 'float-border))
  (define panels (list p1 p2 p3))
  (panels-sync! panels)
  (define focus (panel-view p2))

  (define s (render-display panels focus W H))
  (bench "render-display（layout+content+compose）" 50 (λ () (render-display panels focus W H)))
  (bench "screen-patch 相同屏（纯 diff）" 100 (λ () (screen-patch s s)))
  (bench "screen-patch #f→s（全量 diff）" 100 (λ () (screen-patch #f s)))
  ;; 全量 patch（含布局+内容+
  (bench "render-display-patch #f（冷启动）" 30 (λ () (render-display-patch panels focus W H #f))))

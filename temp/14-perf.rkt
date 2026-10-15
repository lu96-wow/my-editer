#lang racket
;;; 14 —— core-rebuild 渲染性能
;;;
;;; 运行：racket temp/14-perf.rkt

(require "../core-rebuild/editor.rkt")

(define (ms) (current-inexact-milliseconds))

(define (bench label n thunk)
  (thunk)                                    ; 预热
  (define t0 (ms))
  (for ([i (in-range n)]) (thunk))
  (define dt (- (ms) t0))
  (printf "  ~a: ~a ms/frame\n" label (exact->inexact (/ dt n))))

(define (lines n)
  (string-join
   (for/list ([i (in-range n)])
     (format "~a: (define x~a (+ 1 2 3)) ;; some comment text here" i i))
   "\n"))

(define (run W H)
  (printf "======== ~ax~a (~a 格) ========\n" W H (* W H))
  (define q (quotient W 4))
  (define fw (quotient W 3))
  (define fh (max 4 (quotient H 3)))
  (define fx (quotient W 3))
  (define fy (quotient H 5))
  (define b1 (make-buffer (lines 3000) "tree"))
  (define b2 (make-buffer (lines 3000) "doc"))
  (define b3 (make-buffer "float\non top\n" "float"))
  (define p1 (buffer-add-panel! b1 (rect 0 0 q H) borders-all #:line-numbers? #t))
  (define p2 (buffer-add-panel! b2 (rect q 0 (- W q) H) '(up down right) #:line-numbers? #t))
  (define p3 (buffer-add-panel! b3 (rect fx fy fw fh) borders-all #:deep 10 #:face 'float-border))
  (define panels (list p1 p2 p3))
  (panels-sync! panels)
  (define focus (panel-view p2))

  (bench "全量 render-display" 30 (λ () (render-display panels focus W H)))

  (define-values (c0 a0 s0) (render-display-patch panels focus W H #f))
  (bench "patch 无变化（两缓存全命中）" 300
         (λ () (render-display-patch panels focus W H c0)))

  (define k (box 0))
  (bench "patch 只动光标（仅 overlay）" 300
         (λ () (set-box! k (add1 (unbox k)))
              (view-set-point! focus (point 0 (modulo (unbox k) 20)))
              (render-display-patch panels focus W H c0)))

  (bench "patch 内容编辑（焦点 view 重渲）" 100
         (λ () (void (buffer-edit! b2 focus (op-type "x")))
              (void (buffer-undo! b2))
              (render-display-patch panels focus W H c0)))

  (define m (box 0))
  (bench "patch 布局变（浮窗移动）" 100
         (λ () (set-box! m (modulo (add1 (unbox m)) 5))
              (define p3* (make-panel (panel-view p3)
                                      (rect (+ fx (unbox m)) fy fw fh) borders-all
                                      #:deep 10 #:face 'float-border))
              (render-display-patch (list p1 p2 p3*) focus W H c0))))

(for ([wh (list (cons 80 24) (cons 160 50) (cons 240 70) (cons 320 100) (cons 400 120))])
  (run (car wh) (cdr wh)))

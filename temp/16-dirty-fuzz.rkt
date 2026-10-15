#lang racket
;;; 16 —— 脏区正确性 fuzz：随机编辑/滚动/移光标/动面板后，
;;;       增量合成出的屏必须与全量 render-display 完全一致（否则脏行漏了）。

(require "../core/editor.rkt")

(random-seed 42)
(define W 44) (define H 16)

(define b1 (make-buffer "aaa\nbbb\nccc\n" "a"))
(define b2 (make-buffer (string-join (for/list ([i (in-range 60)]) (format "doc line ~a" i)) "\n") "b"))

(define p1 (buffer-add-panel! b1 (rect 0 0 20 H) borders-all #:line-numbers? #t))
(define p2 (buffer-add-panel! b2 (rect 20 0 24 H) '(up down right) #:line-numbers? #t))
(define v1 (panel-view p1))
(define v2 (panel-view p2))
(define panels0 (list p1 p2))
(panels-sync! panels0)

(define cache #f)
(define cur panels0)

(define (panel1 dy) (make-panel v1 (rect 0 dy 20 (- H dy)) borders-all))
(define (panel2 dy) (make-panel v2 (rect 20 dy 24 (- H dy)) '(up down right)))

(define (do-random!)
  (let ([r (random 7)])
    (cond
      [(= r 0) (void (buffer-edit! b2 v2 (op-type "x")))]
      [(= r 1) (view-set-point! v2 (point (random 20) (random 5)))]
      [(= r 2) (view-scroll-to-line! v2 (random 30))]
      [(= r 3) (view-set-point! v1 (point (random 3) (random 3)))]
      [(= r 4) (view-scroll-to-line! v1 (random 3))]
      [(= r 5) (define d (random 4))
               (set! cur (list (panel1 d) (panel2 d)))
               (panels-sync! cur)]
      [else (void (buffer-edit! b1 v1 (op-type "y")))])))

(define (step! i)
  (do-random!)
  (define-values (c r s) (render-display-patch cur v2 W H cache))
  (set! cache c)
  (define expected (render-display cur v2 W H))
  (unless (equal? (screen->string (render-cache-screen c)) (screen->string expected))
    (error 'fuzz "step ~a 屏不一致" i)))

(for ([i (in-range 800)]) (step! i))
(displayln "dirty fuzz: 800 步全部一致 ✓")

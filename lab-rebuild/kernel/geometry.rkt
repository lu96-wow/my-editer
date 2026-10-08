#lang racket

;;; lab-rebuild/kernel/geometry.rkt —— 工作区几何：方向导航（主区叶 + dock 统一算）。

(require "editor-api.rkt" "session.rkt" "runtime.rkt" "workspace.rkt")

(provide pane-dir hit-pane anchor-screen-pos)

(define (rect-v-overlap? a b)
  (and (< (rectangle-y a) (+ (rectangle-y b) (rectangle-height b)))
       (< (rectangle-y b) (+ (rectangle-y a) (rectangle-height a)))))
(define (rect-h-overlap? a b)
  (and (< (rectangle-x a) (+ (rectangle-x b) (rectangle-width b)))
       (< (rectangle-x b) (+ (rectangle-x a) (rectangle-width a)))))

;; 按方向取最近的窗格 vid；同排 / 同列（正交轴重叠）优先。
(define (pane-dir ctx dir)
  (define s (ctx-session ctx))
  (define rects (workspace->rectangles (session-workspace s) (session-width s) (session-height s)))
  (define cur (session-focus-vid s))
  (cond
    [(or (not cur) (null? (cdr rects))) #f]
    [else
     (define c (for/first ([r (in-list rects)] #:when (eqv? cur (rectangle-view-id r))) r))
     (cond
       [(not c) #f]
       [else
        (define cx (+ (rectangle-x c) (quotient (rectangle-width c) 2)))
        (define cy (+ (rectangle-y c) (quotient (rectangle-height c) 2)))
        (define horiz? (memq dir '(left right)))
        (define best
          (for/fold ([best #f]) ([r (in-list rects)] #:unless (eqv? (rectangle-view-id r) cur))
            (define rx (+ (rectangle-x r) (quotient (rectangle-width r) 2)))
            (define ry (+ (rectangle-y r) (quotient (rectangle-height r) 2)))
            (define ok (case dir
                         [(left)  (< rx cx)] [(right) (> rx cx)]
                         [(up)    (< ry cy)] [(down)  (> ry cy)]
                         [else #f]))
            (if (not ok)
                best
                (let* ([overlap? (if horiz? (rect-v-overlap? c r) (rect-h-overlap? c r))]
                       [primary (if horiz? (abs (- rx cx)) (abs (- ry cy)))]
                       [score (+ primary (if overlap? 0 10000))])
                  (if (or (not best) (< score (car best)))
                      (cons score (rectangle-view-id r))
                      best)))))
        (and best (cdr best))])]))

;; 屏幕坐标 → 命中的窗格 rectangle / #f（鼠标用）。
(define (hit-pane ctx x y)
  (define s (ctx-session ctx))
  (define rects (workspace->rectangles (session-workspace s) (session-width s) (session-height s)))
  (for/first ([r (in-list rects)]
              #:when (and (>= x (rectangle-x r)) (< x (+ (rectangle-x r) (rectangle-width r)))
                          (>= y (rectangle-y r)) (< y (+ (rectangle-y r) (rectangle-height r)))))
    r))

;; 某视图内某点的屏幕绝对坐标 / (values #f #f)（浮层锚点用）。
(define (anchor-screen-pos ctx vid p)
  (define s (ctx-session ctx))
  (define rects (workspace->rectangles (session-workspace s) (session-width s) (session-height s)))
  (define r (for/first ([r (in-list rects)] #:when (eqv? vid (rectangle-view-id r))) r))
  (define-values (row col)
    (editor-view-point->screen-position (session-editor s) vid p))
  (if (and row r)
      (values (+ (rectangle-y r) row) (+ (rectangle-x r) col))
      (values #f #f)))

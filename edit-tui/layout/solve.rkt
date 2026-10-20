#lang racket

;;; edit-tui-rebuild/layout/solve.rkt —— layout -> rects / seams（纯几何）
;;;
;;; 输入 layout 状态 + 可用区域，输出：
;;;   panel 的 rect、split 的 rect、可拖动的 seam
;;;
;;; 固定尺寸策略：固定轴先取，剩余给 flex；两边都固定时第二个吸收余量。
;;; 隐藏 leaf 直接跳过，兄弟吸收父 rect。

(require "../../core/view/base/rect.rkt"
         "tree.rkt")

(provide
 (struct-out seam)
 (struct-out layout-solution)
 axis-extent
 round-ratio
 allocate
 make-seam-rect
 layout-solve
 layout-panel-rects
 layout-split-rects
 layout-seams
 layout-seam-at
 layout-panel-id-at)

;;; ════════════════ layout-solve ════════════════

(struct seam (split-id axis rect) #:transparent)
(struct layout-solution (panel-rects split-rects seams) #:transparent)
;; panel-rects : panel-id -> rect（仅可见 panel）
;; split-rects : split-id -> rect
;; seams       : (listof seam)，按树序

(define (axis-extent r axis)
  (case axis
    [(lr) (rect-w r)]
    [(tb) (rect-h r)]
    [else (error 'axis-extent "axis 要是 'lr 或 'tb：~a" axis)]))

(define (round-ratio E ratio)
  (max 0 (min E (inexact->exact (round (* E ratio))))))

;; → (values first-extent second-extent)
(define (allocate E fixed-first fixed-second ratio)
  (define E* (max 0 E))
  (cond
    [(and fixed-first fixed-second)
     (define f (min E* fixed-first))
     (values f (- E* f))]
    [fixed-first
     (define f (min E* fixed-first))
     (values f (- E* f))]
    [fixed-second
     (define s (min E* fixed-second))
     (values (- E* s) s)]
    [else
     (define f (round-ratio E* ratio))
     (values f (- E* f))]))

(define (make-seam-rect axis left-r right-r)
  ;; 接缝覆盖两侧边界格，方便鼠标在任一侧边框上拖动。
  (case axis
    [(lr) (rect (max 0 (sub1 (rect-x right-r))) (rect-y right-r)
                2 (rect-h right-r))]
    [(tb) (rect (rect-x right-r) (max 0 (sub1 (rect-y right-r)))
                (rect-w right-r) 2)]
    [else (error 'make-seam-rect "axis 要是 'lr 或 'tb：~a" axis)]))

(define (layout-solve l area)
  (define rects (make-hasheq))
  (define split-rects (make-hasheq))
  (define seams '())
  (define (walk n r)
    (cond
      [(not n) (void)]
      [(leaf? n)
       (when (layout-subtree-visible? l n)
         (hash-set! rects (leaf-panel-id n) r))]
      [else
       (hash-set! split-rects (split-id n) r)
       (define axis (split-axis n))
       (define left (split-left n))
       (define right (split-right n))
       (define lv? (layout-subtree-visible? l left))
       (define rv? (layout-subtree-visible? l right))
       (cond
         [(not lv?)
          (when rv? (walk right r))]
         [(not rv?)
          (walk left r)]
         [else
          (define E (axis-extent r axis))
          (define-values (e1 e2)
            (allocate E
                      (node-fixed-size l left axis)
                      (node-fixed-size l right axis)
                      (split-ratio n)))
          (define-values (r1 r2)
            (case axis
              [(lr)
               (values (rect (rect-x r) (rect-y r) e1 (rect-h r))
                       (rect (+ (rect-x r) e1) (rect-y r) e2 (rect-h r)))]
              [(tb)
               (values (rect (rect-x r) (rect-y r) (rect-w r) e1)
                       (rect (rect-x r) (+ (rect-y r) e1) (rect-w r) e2))]))
          (walk left r1)
          (walk right r2)
          (set! seams (cons (seam (split-id n) axis (make-seam-rect axis r1 r2))
                            seams))])]))
  (walk (layout-root l) area)
  (layout-solution rects split-rects (reverse seams)))

(define (layout-panel-rects l area)
  (layout-solution-panel-rects (layout-solve l area)))

(define (layout-split-rects l area)
  (layout-solution-split-rects (layout-solve l area)))

(define (layout-seams l area)
  (layout-solution-seams (layout-solve l area)))

(define (layout-seam-at l area row col)
  (for/first ([s (in-list (layout-seams l area))]
              #:when (rect-contains? (seam-rect s) col row))
    s))

(define (layout-panel-id-at l area row col)
  (for/first ([(id r) (in-hash (layout-panel-rects l area))]
              #:when (rect-contains? r col row))
    id))



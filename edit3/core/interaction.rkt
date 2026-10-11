#lang racket

;;; edit3/interaction.rkt —— 指针交互（纯状态机）
;;;
;;;   idle --press(命中 handle)--> dragging(handle, 起点, 快照)
;;;   dragging --move--> 按 handle 改 tiling.basis / float.anchor+size
;;;   dragging --release--> idle
;;;
;;; 拖动用**总位移**（起点在 press 时记下），不累积误差；快照存按下时的原值，
;;; 每次 move 都从原值算，所以反复 move 不会漂。

(provide pointer-press pointer-move pointer-release)

(require "state.rkt" "event.rkt" "layout.rkt" "resize.rkt" racket/list)

;; anchor 解析成矩形（浮窗 rel = 'screen | wid）。
(define (float-rel-rect g f)
  (define a (float-anchor f))
  (cond
    [(eq? (anchor-rel a) 'screen) (rect 0 0 (geometry-w g) (geometry-h g))]
    [else
     (define p (findf (lambda (p) (eqv? (anchor-rel a) (placement-wid p)))
                      (geometry-placements g)))
     (if p (placement-rect p) (rect 0 0 (geometry-w g) (geometry-h g)))]))

;; 缝的可移动量：两侧都不越过 min。
(define (clamp-delta lens mins index delta)
  (define a (list-ref lens index))
  (define b (list-ref lens (add1 index)))
  (define ma (list-ref mins index))
  (define mb (list-ref mins (add1 index)))
  (max (- ma a) (min (- b mb) delta)))

(define (pointer-press g st ev)
  (define x (cursor-event-x ev))
  (define y (cursor-event-y ev))
  (define h (hit g x y))
  (cond
    [(handle? h)
     (define snap
       (case (handle-kind h)
         [(boundary) (match-define (list _axis _path _index lens mins bases) (handle-data h))
                     (list 'boundary lens mins bases)]
         [else (match-define (list wid edge) (handle-data h))
               (list 'float (float-by-id (state-floats st) wid) edge)]))
     (define fo (if (eq? (handle-kind h) 'boundary)
                    (state-focus st)
                    (car (handle-data h))))
     (struct-copy state st [focus fo] [drag (dragging h x y snap)])]
    [(placement? h) (struct-copy state st [focus (placement-wid h)])]
    [else st]))

(define (pointer-move g st ev)
  (define d (state-drag st))
  (cond
    [(not (dragging? d)) st]
    [else
     (define x (cursor-event-x ev))
     (define y (cursor-event-y ev))
     (define dx (- x (dragging-start-x d)))
     (define dy (- y (dragging-start-y d)))
     (match (dragging-snapshot d)
       [(list 'boundary lens mins bases)
        (define h (dragging-handle d))
        (match-define (list axis path index _ _ _) (handle-data h))
        (define delta (if (eq? axis 'h) dx dy))
        (define d* (clamp-delta lens mins index delta))
        (struct-copy state st
                     [tiling (layout-set-bases
                              (state-tiling st) path index
                              (+ (list-ref bases index) d*)
                              (- (list-ref bases (add1 index)) d*))])]
       [(list 'float f0 edge)
        (define floats*
          (if (eq? edge 'move)
              (set-float (state-floats st) (float-wid f0) (move-float* f0 dx dy))
              (set-float (state-floats st) (float-wid f0)
                         (resize-float* f0 edge dx dy
                                        (float-rel-rect g f0)
                                        (geometry-w g) (geometry-h g)))))
        (struct-copy state st [floats floats*])]
       [_ st])]))

(define (pointer-release st ev)
  (if (dragging? (state-drag st))
      (struct-copy state st [drag (idle)])
      st))

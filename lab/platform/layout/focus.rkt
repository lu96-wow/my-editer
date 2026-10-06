#lang racket

(require "../../../core/editor.rkt")

;;; lab-rebuild/base/layout/focus.rkt —— 按几何方向找邻居 pane（纯）
;;;
;;; 只认 rectangle 列表，不认识 editor / 焦点语义：给定当前 vid 和方向，
;;; 找中心曼哈顿距离最近的邻 pane。空 / 无邻居 → #f。

(provide pane-dir pane-left pane-right pane-up pane-down)

(define (rect-right r) (+ (rectangle-x r) (rectangle-width r)))
(define (rect-bottom r) (+ (rectangle-y r) (rectangle-height r)))
(define (rect-cx r) (+ (rectangle-x r) (quotient (rectangle-width r) 2)))
(define (rect-cy r) (+ (rectangle-y r) (quotient (rectangle-height r) 2)))

(define (v-overlap? r0 r1) (and (< (rectangle-y r0) (rect-bottom r1))
                                (< (rectangle-y r1) (rect-bottom r0))))
(define (h-overlap? r0 r1) (and (< (rectangle-x r0) (rect-right r1))
                                (< (rectangle-x r1) (rect-right r0))))

;; panes : (listof rectangle)；dir : 'left | 'right | 'up | 'down
(define (pane-dir panes vid dir)
  (define cur (for/first ([r (in-list panes)] #:when (eqv? (rectangle-view-id r) vid)) r))
  (and cur
       (let ([cx (rect-cx cur)] [cy (rect-cy cur)])
         (define cands
           (for/list ([r (in-list panes)]
                      #:unless (eqv? (rectangle-view-id r) vid)
                      #:when (case dir
                               [(left)  (and (< (rect-cx r) cx) (v-overlap? cur r))]
                               [(right) (and (> (rect-cx r) cx) (v-overlap? cur r))]
                               [(up)    (and (< (rect-cy r) cy) (h-overlap? cur r))]
                               [(down)  (and (> (rect-cy r) cy) (h-overlap? cur r))]
                               [else (error 'pane-dir "dir 必须是 left/right/up/down，得到 ~a" dir)]))
             r))
         (and (pair? cands)
              (rectangle-view-id
               (argmin (lambda (r) (+ (abs (- (rect-cx r) cx)) (abs (- (rect-cy r) cy))))
                       cands))))))

(define (pane-left  panes vid) (pane-dir panes vid 'left))
(define (pane-right panes vid) (pane-dir panes vid 'right))
(define (pane-up    panes vid) (pane-dir panes vid 'up))
(define (pane-down  panes vid) (pane-dir panes vid 'down))

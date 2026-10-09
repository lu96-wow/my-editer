#lang racket

;;; edit/command/session-mouse.rkt —— 鼠标（命中 / 点击定位 / 滚轮）
;;;
;;; 屏幕坐标命中已放置视图；点击 = 聚焦 + 定位光标；滚轮 = 滚命中视图（不改焦点）。

(require "session-value.rkt"
         "session-core.rkt"
         "session-window.rkt"
         "../../core/editor.rkt"
         "../../core/text/base/point.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt")

(provide session-view-at session-mouse-press session-mouse-scroll)

(define (session-view-at s col row)
  (for/first ([p (in-list (session-views s))]
              #:when (and (>= col (placed-x p)) (< col (+ (placed-x p) (placed-w p)))
                          (>= row (placed-y p)) (< row (+ (placed-y p) (placed-h p)))))
    (placed-vid p)))

(define (session-mouse-press s col row)
  (sync-layout! s)
  (define p (for/first ([p (in-list (session-views s))]
                        #:when (and (>= col (placed-x p)) (< col (+ (placed-x p) (placed-w p)))
                                    (>= row (placed-y p)) (< row (+ (placed-y p) (placed-h p)))))
              p))
  (cond
    [(not p) s]
    [else
     (define vid (placed-vid p))
     (define s1 (session-set-focus s (focus-set (session-focus s) vid)))
     (define-values (line c)
       (editor-view-screen-position->point (session-ed s) vid
                                           (- row (placed-y p)) (- col (placed-x p))))
     (when line (editor-view-set-point! (session-ed s) vid (point line c)))
     s1]))

(define (session-mouse-scroll s col row delta)
  (sync-layout! s)
  (define vid (session-view-at s col row))
  (when vid (editor-view-scroll! (session-ed s) vid delta))
  s)

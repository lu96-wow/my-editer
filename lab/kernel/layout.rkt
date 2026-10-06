#lang racket

;;; lab-rebuild/kernel/layout.rkt —— 布局纯派生 + 命中测试 + 锚点。
;;;
;;; 区域：左栏（面板）+ 主区（frame 树）+ 底部槽位（status/input）。
;;; 渲染 / 鼠标 / 浮层锚点共用同一套派生，避免重复。

(require "editor-api.rkt" "session.rkt" "frame.rkt" "panel.rkt"
         "runtime.rkt" "pipeline.rkt")

(provide layout-info hit-pane anchor-screen-pos)

;; → (values (listof rectangle) width height)
(define (layout-info ctx)
  (define s (ctx-session ctx))
  (define w (session-width s))
  (define h (session-height s))
  (define p (and (session-sidebar? s) (shown-panel (session-panels s) (session-active-panel s))))
  (define-values (sw main) (workspace-main-area w h (and p #t) (session-sidebar-width s)))
  (define-values (rects _bars) (frame->rectangles (session-frame s) main))
  (define left-rects (if p (list (rectangle (panel-vid p) 0 0 sw h 0)) '()))
  (define slot-rect (rectangle (effective-slot-vid ctx) sw (sub1 h) (area-w main) 1 0))
  (values (append left-rects rects (list slot-rect)) w h))

;; 屏幕坐标 → 命中的窗格矩形 / #f（鼠标用）。
(define (hit-pane ctx x y)
  (define-values (rects _w _h) (layout-info ctx))
  (for/first ([r (in-list rects)]
              #:when (and (>= x (rectangle-x r)) (< x (+ (rectangle-x r) (rectangle-width r)))
                          (>= y (rectangle-y r)) (< y (+ (rectangle-y r) (rectangle-height r)))))
    r))

;; 某视图内某点的屏幕绝对坐标 / (values #f #f)。
(define (anchor-screen-pos ctx vid p)
  (define-values (rects _w _h) (layout-info ctx))
  (define r (for/first ([r (in-list rects)] #:when (eqv? vid (rectangle-view-id r))) r))
  (define-values (row col)
    (editor-view-point->screen-position (session-editor (ctx-session ctx)) vid p))
  (if (and row r)
      (values (+ (rectangle-y r) row) (+ (rectangle-x r) col))
      (values #f #f)))

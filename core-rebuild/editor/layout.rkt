#lang racket

;;; core-rebuild/editor/layout.rkt —— panel.rect 驱动 view 尺寸（显式同步）
;;;
;;; 尺寸的唯一真相在 panel.rect（内容区 = panel-content）。view 的 viewport 尺寸是派
;;; 生量，只能由这里写。宿主在「布局变化 / 换 view」之后显式调用；不动时是 no-op。
;;; 渲染保持纯，绝不 resize（见 editor/render.rkt）。
;;;
;;; view 可替换：换 view 后调用 panels-sync!，新 view 被落到内容尺寸；下一帧
;;; screen-patch 自然把内容差量算出来。

(require "ops.rkt" "query.rkt"
         "../view/panel.rkt" "../view/base/rect.rkt")

(provide panel-sync!                 ; panel → void
         panels-sync!)               ; (listof panel) → void

(define (panel-sync! p)
  (define c (panel-content p))
  (define v (panel-view p))
  (define w (max 1 (rect-w c)))       ; viewport 最小 1
  (define h (max 1 (rect-h c)))
  (unless (and (= w (view-width v)) (= h (view-height v)))
    (view-resize! v w h)))

(define (panels-sync! ps)
  (for-each panel-sync! ps))

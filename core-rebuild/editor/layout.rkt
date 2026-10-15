#lang racket

;;; core-rebuild/editor/layout.rkt —— panel ↔ view（显式同步 + 一步构造）
;;;
;;; 尺寸的唯一真相在 panel.rect（内容区 = panel-content）。view 的 viewport 尺寸是派
;;; 生量，只能由这里写。宿主在「布局变化 / 换 view」之后显式调用；不动时是 no-op。
;;; 渲染保持纯，绝不 resize（见 editor/render.rkt）。
;;;
;;; view 可替换：换 view 后调用 panels-sync!，新 view 被落到内容尺寸；下一帧
;;; screen-patch 自然把内容差量算出来。

(require "state.rkt" "ops.rkt" "query.rkt"
         "../view/panel.rkt" "../view/base/rect.rkt")

(provide panel-sync!                 ; panel → void
         panels-sync!                ; (listof panel) → void
         buffer-add-panel!)          ; buffer rect borders … → panel（含新 view）

(define (panel-sync! p)
  (define c (panel-content p))
  (define v (panel-view p))
  (define w (max 1 (rect-w c)))       ; viewport 最小 1
  (define h (max 1 (rect-h c)))
  (unless (and (= w (view-width v)) (= h (view-height v)))
    (view-resize! v w h)))

(define (panels-sync! ps)
  (for-each panel-sync! ps))

;;; ---------- 一步：buffer → panel（含新 view）----------
;;;
;;; 建一个 view 挂到 buffer，包成 panel，并立刻 sync 到内容尺寸。
;;; 关键字同 buffer-add-view!，外加 panel 的 #:deep / #:face。
;;; 返回 panel（view 用 panel-view 取；已在 buffer.views 里）。

(define (buffer-add-panel! b rect borders
                           #:deep [deep 0]
                           #:face [face 'window-border]
                           #:mode [mode 'clip]
                           #:line-numbers? [line-numbers? #f]
                           #:selections [sels #f])
  (define v (if sels
                (buffer-add-view! b #:mode mode #:line-numbers? line-numbers? #:selections sels)
                (buffer-add-view! b #:mode mode #:line-numbers? line-numbers?)))
  (define p (make-panel v rect borders #:deep deep #:face face))
  (panel-sync! p)
  p)

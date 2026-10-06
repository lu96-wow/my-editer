#lang racket

;;; lab-rebuild/kernel/render.rkt —— 每帧：before-render 通知 → 布局 → core 合成。
;;;
;;; 布局（layout.rkt 纯派生）⊕ 浮层（overlay 的每帧 pane）→ core 合成。

(require "editor-api.rkt" "session.rkt" "runtime.rkt" "layout.rkt" "overlay.rkt" "pipeline.rkt")

(provide app-render app-render-patch hit-pane)

(define (app-render ctx)
  (define ctx1 (run-notify ctx 'before-render '()))
  (define s (ctx-session ctx1))
  (define-values (rects w h) (layout-info ctx1))
  (values ctx1
          (editor-render-layout*! (session-editor s) rects (session-focus-vid s) w h
                                  (overlay-panes ctx1))))

;; 增量：旧帧 + 本帧 → (values ctx screen render selection)；render/selection 是 piece。
;; ⚠ 必须先 editor-set-layout!：patch 路径的 core 函数不会落尺寸，
;;   否则 view 视口尺寸停在创建时 → view-ensure! 按错宽高算，光标就不跟随。
(define (app-render-patch ctx old)
  (define ctx1 (run-notify ctx 'before-render '()))
  (define s (ctx-session ctx1))
  (define-values (rects w h) (layout-info ctx1))
  (editor-set-layout! (session-editor s) rects)
  (define-values (new render selection)
    (editor-render-layout-patch (session-editor s) old rects (session-focus-vid s) w h
                                (overlay-panes ctx1)))
  (values ctx1 new render selection))

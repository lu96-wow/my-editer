#lang racket

;;; lab-rebuild/kernel/render.rkt —— 每帧：before-render 通知 → 工作区布局 → core 合成。

(require "editor-api.rkt" "session.rkt" "runtime.rkt" "workspace.rkt" "overlay.rkt" "pipeline.rkt")

(provide app-render app-render-patch)

(define (render-rects ctx1)
  (define s (ctx-session ctx1))
  (values (workspace->rectangles (session-workspace s) (session-width s) (session-height s))
          (session-width s) (session-height s)))

(define (app-render ctx)
  (define ctx1 (run-notify ctx 'before-render '()))
  (define s (ctx-session ctx1))
  (define-values (rects w h) (render-rects ctx1))
  (editor-render-layout*! (session-editor s) rects (session-focus-vid s) w h
                          (overlay-panes ctx1)))

;; 增量：旧帧 + 本帧 → (values ctx screen render selection)；render/selection 是 piece 列表。
;; ⚠ 先 editor-set-layout! 落尺寸，否则 patch 路径不会更新 view 尺寸。
(define (app-render-patch ctx old)
  (define ctx1 (run-notify ctx 'before-render '()))
  (define s (ctx-session ctx1))
  (define-values (rects w h) (render-rects ctx1))
  (editor-set-layout! (session-editor s) rects)
  (define-values (new render selection)
    (editor-render-layout-patch (session-editor s) old rects (session-focus-vid s) w h
                                (overlay-panes ctx1)))
  (values ctx1 new render selection))

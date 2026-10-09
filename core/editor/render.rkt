#lang racket

(require "state.rkt"
         "../view/render.rkt" "../view/patch.rkt")

;;; editor/render.rkt —— 单视图渲染 + 增量投影
;;;
;;; 多视图合成在 layout.rkt（rectangle 版）。这里只有：
;;;   editor-view-render   单视图 → screen
;;;   editor-render-patch  旧帧 + 新帧 → (新帧, render, selection)
;;;

(provide
 ;; ---------- 单视图 ----------
 editor-view-render

 ;; ---------- 增量投影 ----------
 editor-render-patch)

(define (editor-view-render ed vid)
  (define v (editor-view-handle ed vid))
  (render (editor-view-document ed vid) (view-viewport v) (view-selections v)))

;; 单视图：旧帧 → (新帧, render, selection)。
(define (editor-render-patch ed vid old)
  (define new (editor-view-render ed vid))
  (define-values (render selection) (screen-patch old new))
  (values new render selection))

#lang racket

(require "state.rkt" "command.rkt" "../view/render.rkt" "../view/compose.rkt"
         "../view/patch.rkt" "../view/base/viewport.rkt")

;;; editor/layout.rkt —— 布局：把 (vid x y w h) 落到 view 与屏幕
;;;
;;; 一个 rectangle = 一块窗格：vid 看哪个视图，x y 贴在哪（屏幕列 / 行），w h 多大。
;;; 尺寸归 view，位置归渲染。
;;;
;;; 三个入口（可拆可合）：
;;;   editor-set-layout!      写：w h → 各 view（变了才重锚）；x y 忽略
;;;   editor-render-layout   读：纯渲染。x y 贴屏，w h 定该帧视口大小（不改 view 状态）
;;;   editor-render-layout*!  组合：先 set-layout! 再 render → screen
;;;
;;; ensure / 上下移动 / 滚动 / 鼠标换算用 view 里存的尺寸，所以布局要把尺寸落到 view；
;;; 纯渲染只覆盖本帧，供出屏。

(provide
 ;; ---------- 类型 ----------
 (struct-out rectangle)

 ;; ---------- 拆 ----------
 editor-set-layout!
 editor-render-layout

 ;; ---------- 合 ----------
 editor-render-layout*!

 ;; ---------- 增量（rectangle 版） ----------
 editor-render-layout-patch)

;; 窗格矩形：x = 屏幕列，y = 屏幕行，w/h = 尺寸；deep = 深度（大 = 在上）。
(struct rectangle (view-id x y width height deep) #:transparent)

;;; ---------- 写：尺寸落到 view ----------

;; 逐个 rectangle：w/h 与 view 当前视口不同才重锚（editor-view-set-size! 保持同锚）。
(define (editor-set-layout! ed rectangles)
  (for ([r (in-list rectangles)])
    (define vp (view-viewport (editor-view-ref ed (rectangle-view-id r))))
    (unless (and (= (rectangle-width r) (viewport-width vp))
                 (= (rectangle-height r) (viewport-height vp)))
      (editor-view-set-size! ed (rectangle-view-id r) (rectangle-width r) (rectangle-height r))))
  (void))

;;; ---------- 读：纯渲染 ----------

;; 按给定本帧尺寸渲染某视图（只覆盖视口的 w/h，不改 view 里存的尺寸 / 锚点）。
(define (view-render-sized ed vid w h)
  (define v (editor-view-ref ed vid))
  (render (editor-view-document ed vid)
          (viewport-set-size (view-viewport v) w h)
          (view-selections v)))

;; 一份 rectangles → 一屏；只有 active（单个 vid / vid 列表）对应窗格的光标 / 选区透出，其余只出文本。
;; decorations：(listof pane)，不在 rectangles 里的额外图层（如分屏分隔线），同样参与合成 / 增量 patch。
(define (editor-render-layout ed rectangles active total-w total-h [decorations '()])
  (composition-screen
   (panes->composition total-w total-h
     (append
      (for/list ([r (in-list rectangles)])
        (pane (rectangle-view-id r) (rectangle-y r) (rectangle-x r)
              (view-render-sized ed (rectangle-view-id r) (rectangle-width r) (rectangle-height r))
              (rectangle-deep r)))
      decorations)
     active)))

;;; ---------- 合 ----------

(define (editor-render-layout*! ed rectangles active total-w total-h [decorations '()])
  (editor-set-layout! ed rectangles)
  (editor-render-layout ed rectangles active total-w total-h decorations))

;; 增量：旧帧 + 新帧 → (新帧, render, selection)。
(define (editor-render-layout-patch ed old rectangles active total-w total-h [decorations '()])
  (define new (editor-render-layout ed rectangles active total-w total-h decorations))
  (define-values (render selection) (screen-patch old new))
  (values new render selection))

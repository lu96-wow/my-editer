#lang racket

(require "state.rkt" "command.rkt" "../view/render.rkt" "../view/compose.rkt"
         "../view/patch.rkt" "../view/base/viewport.rkt")

;;; editor/layout.rkt —— 布局：把 (vid x y w h) 落到 view 与屏幕
;;;
;;; 一个 rect = 一块窗格：vid 看哪个视图，x y 贴在哪（屏幕列 / 行），w h 多大。
;;; 一份 rect 列表就是**宿主的唯一布局输入**：尺寸归 view，位置归渲染。
;;;
;;; 三个入口（可拆可合）：
;;;   editor-set-layout      写：w h → 各 view（变了才重锚 + 同步跟随者）；x y 忽略
;;;   editor-render-layout   读：纯渲染。x y 贴屏，w h 定该帧视口大小（**不改 view 状态**）
;;;   editor-render-layout*  组合：先 set-layout 再 render，→ (values editor screen)
;;;
;;; 为什么要 set-layout：ensure / 上下移动 / 滚动 / 鼠标换算用 view 里存的尺寸，
;;; 所以布局要把尺寸落到 view；纯渲染只覆盖本帧，供出屏。

(provide
 ;; ---------- 类型 ----------
 (struct-out rect)

 ;; ---------- 拆 ----------
 editor-set-layout
 editor-render-layout

 ;; ---------- 合 ----------
 editor-render-layout*

 ;; ---------- 增量（rect 版） ----------
 editor-render-layout-patch)

;; 窗格矩形：x = 屏幕列，y = 屏幕行，w/h = 尺寸。
(struct rect (vid x y w h) #:transparent)

;;; ---------- 写：尺寸落到 view ----------

;; 逐个 rect：w/h 与 view 当前视口不同才重锚（editor-view-set-size! 会同步跟随者）。就地、返回 ed。
(define (editor-set-layout ed rects)
  (for ([r (in-list rects)])
    (define vp (view-viewport (editor-view-ref ed (rect-vid r))))
    (unless (and (= (rect-w r) (viewport-width vp))
                 (= (rect-h r) (viewport-height vp)))
      (editor-view-set-size! ed (rect-vid r) (rect-w r) (rect-h r))))
  ed)

;;; ---------- 读：纯渲染 ----------

;; 按给定本帧尺寸渲染某视图（只覆盖视口的 w/h，不改 view 里存的尺寸 / 锚点）。
(define (view-render-sized ed vid w h)
  (define v (editor-view-ref ed vid))
  (render (editor-view-document ed vid)
          (viewport-set-size (view-viewport v) w h)
          (view-selections v)))

;; 一份 rects → 一屏；active-vid 的光标透出，其余只带选区。
(define (editor-render-layout ed rects active-vid total-w total-h)
  (composition-screen
   (panes->composition total-w total-h
     (for/list ([r (in-list rects)])
       (pane (rect-vid r) (rect-y r) (rect-x r)
             (view-render-sized ed (rect-vid r) (rect-w r) (rect-h r))))
     active-vid)))

;;; ---------- 合 ----------

(define (editor-render-layout* ed rects active-vid total-w total-h)
  (define ed* (editor-set-layout ed rects))
  (values ed* (editor-render-layout ed* rects active-vid total-w total-h)))

;; 增量：旧帧 + 新帧 → (新帧, render, selection)。
(define (editor-render-layout-patch ed old rects active-vid total-w total-h)
  (define new (editor-render-layout ed rects active-vid total-w total-h))
  (define-values (render selection) (screen-patch old new))
  (values new render selection))

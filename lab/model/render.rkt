#lang racket

;;; lab/model/render.rkt —— 把布局树投影成一屏
;;;
;;; 每个叶子各自出一屏（editor 叶子用 core `editor-render-layout` 单位置渲染；
;;; file-tree 用 lab 自己的占位投影），再用 core `panes->screen` 合成。
;;; 渲染只读：`editor-render-layout` 在 view 的**副本**上施加尺寸，不改 view 状态。

(require
 "layout.rkt"
 "session.rkt"
 "../../core/editor.rkt"
 (prefix-in compose: "../../core/view/compose.rkt")
 "../../core/view/base/screen.rkt"
 "../../core/view/patch.rkt")

(provide
 session-render
 session-render-patch
 status-screen)

;;; ---------- 单叶子 → screen ----------

(define (pane-screen s r)
  (define id (pane-rect-id r))
  (define w (max 1 (pane-rect-w r)))
  (define h (max 1 (pane-rect-h r)))
  (cond
    [(eq? id 'status) (status-screen s w h)]
    [else
     (editor-render-layout (session-editor s)
                           (list (rect id 0 0 w h 0))
                           id w h)]))

;; 底部状态栏：prompt 激活时显示输入行，否则显示简单状态。
(define (status-screen s w h)
  (define w* (max 1 w))
  (define h* (max 1 h))
  (define p (session-prompt s))
  (define text (if p (string-append (prompt-label p) (prompt-text p)) "lab"))
  (screen w* h* (vector (list (run 0 text 'status))) '() '()))

;;; ---------- 全屏合成 ----------

(define (session-render s)
  (define rects (session-rects s))
  (define panes
    (for/list ([r (in-list rects)])
      (compose:pane (pane-rect-id r)
                    (pane-rect-y r) (pane-rect-x r)
                    (pane-screen s r)
                    0)))
  (compose:panes->screen (session-cols s) (session-rows s) panes (session-active s)))

;;; ---------- 增量 ----------

;; 旧帧 → (新帧 render 差量 selection 差量)。
(define (session-render-patch s old)
  (define new (session-render s))
  (define-values (render selection) (screen-patch old new))
  (values new render selection))

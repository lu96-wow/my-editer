#lang racket

;;; core-rebuild/editor/render.rkt —— 渲染：panel display list → screen
;;;
;;;   panel = (view rect borders deep face)     宿主直接给 panel 值
;;;   逐 panel：view → buffer → document，按 view 自己的 viewport 渲染 → content pane
;;;   全局：     panel 列表 → 可见边格（owner-first）→ run → border pane
;;;   panes->composition 合成（z 序 / 遮挡）；compose 不认识任何 id
;;;
;;; 浮窗 = deep 高的 panel：内容 + 边框一起按 deep 被遮挡，一次合成、一次 diff。
;;; 尺寸属于 panel.rect：布局变化由 panels-sync! 落进 view.viewport；
;;; 渲染保持纯，不写回任何状态。

(require "state.rkt" "query.rkt"
         "../view/render.rkt" "../view/patch.rkt" "../view/compose.rkt"
         "../view/base/screen.rkt"
         "../view/panel.rkt" "../view/border.rkt" "../view/base/rect.rkt")

(provide
 panel-cursor-position            ; panel → 主光标绝对屏幕位置 (values row col) | (values #f #f)
 render-display                   ; panels focus w h → screen
 render-display-patch)            ; panels focus w h old → (values screen render selection)

;; focus：#f | view | (listof view)。命中的 view 才画 overlay（光标/选区）。
(define (focus-views focus)
  (cond [(not focus) '()]
        [(list? focus) focus]
        [else (list focus)]))

;; 该 panel 的 view 主光标在合成屏上的绝对位置（= view 内坐标 + 内容区原点）。
(define (panel-cursor-position p)
  (define v (panel-view p))
  (define c (panel-content p))
  (define-values (r col) (view-cursor-screen-position v))
  (if r (values (+ (rect-y c) r) (+ (rect-x c) col))
        (values #f #f)))

;; display list → screen。纯。
(define (render-display panels focus total-w total-h)
  (define focs (focus-views focus))
  (composition-screen
   (panes->composition
    total-w total-h
    (append
     ;; 内容 pane：view 内容贴到内容区原点，带该 panel 的 deep
     (for/list ([p (in-list panels)])
       (define v (panel-view p))
       (define c (panel-content p))
       (define cw (rect-w c)) (define ch (rect-h c))
       (define sels (and (memq v focs) (view-selections v)))
       (and (> cw 0) (> ch 0)
            (pane (rect-y c) (rect-x c)
                  (render (view-document v) (view-viewport v) sels)
                  (panel-deep p))))
     ;; 边框 pane：每段 run 一个 1×N，带 owner 的 face / deep
     (for/list ([b (in-list (panels->border-runs panels))])
       (match-define (list row col text face deep) b)
       (pane row col
             (screen (string-length text) 1
                     (vector (list (run 0 text face))) '() '())
             deep))))))

;; 增量：旧帧 + 新帧 → (新帧, render pieces, selection pieces)。
(define (render-display-patch panels focus total-w total-h old)
  (define new (render-display panels focus total-w total-h))
  (define-values (render selection) (screen-patch old new))
  (values new render selection))

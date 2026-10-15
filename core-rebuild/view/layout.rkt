#lang racket

;;; core-rebuild/view/layout.rkt —— 布局骨架（每帧只依赖 panels，不依赖内容 / 焦点）
;;;
;;; 渲染分两层，这里是「布局层」的产物：
;;;   placements  : 每块 panel 的 (view 内容 rect deep) —— 内容 pane 往哪贴
;;;   border-runs : 全局收边 + owner 过滤 + 同向延续字形 —— 边框 pane 画什么
;;;
;;; 只依赖 panel（rect / borders / deep / face），跟 view 内容、焦点、selections 无关。
;;; 所以布局不变时这一层可以整个复用（见 editor/render.rkt 的 render-cache）。

(require "base/rect.rkt" "panel.rkt" "border.rkt")

(provide (struct-out layout)       ; placements / border-runs
         panels->layout)

(struct layout (placements border-runs) #:transparent)
;; placements  : (listof (list view content-rect deep))
;; border-runs : (listof (row col text face deep))

(define (panels->layout panels)
  (layout
   (for/list ([p (in-list panels)])
     (list (panel-view p) (panel-content p) (panel-deep p)))
   (panels->border-runs panels)))

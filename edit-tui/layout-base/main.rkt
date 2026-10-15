#lang racket

;;; edit-tui/layout-base/main.rkt —— 布局层入口（只做再导出）
;;;
;;; 分成三块：
;;;   rect     矩形算术（唯一几何值）
;;;   panel    面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face + 内容区 + 命中
;;;   border   面板边框 → 装饰 pane：跨 panel 收集边、按同向延续取字形、合成 run
;;;
;;; 边框只认 panel 的几何（rect / borders / deep / face），不碰 core 的渲染值（piece）；
;;; 产出的 pane 交给 core 的合成（panes->screen）。

(provide (all-from-out "rect.rkt" "panel.rkt" "border.rkt"))

(require "rect.rkt"
         "panel.rkt"
         "border.rkt")

#lang racket

;;; edit-tui/layout-base/main.rkt —— 布局层入口（只做再导出）
;;;
;;; 布局 = 一堆面板（panel）：外框矩形 + 四条边可选边框 + 深度 + 边框 face。
;;; 不必布满屏幕。纯几何 + 定位：
;;;   rect     矩形算术
;;;   panel    面板 + 内容区 + 命中 + 面板 → display-entry
;;;
;;; 边框的**画**（字形 / face / pane）在 core-render/border.rkt。

(provide (all-from-out "rect.rkt" "panel.rkt"))

(require "rect.rkt"
         "panel.rkt")

#lang racket

;;; edit-tui/layout-base/main.rkt —— 布局层入口（只做再导出）
;;;
;;; 分成两层：
;;;   rect     矩形算术（唯一几何值）
;;;   panel    面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face + 内容区 + 命中
;;;
;;; 边框的**画**（字形 / face / pane）在 core-render/border.rkt —— 那里把所有 panel
;;; 的边收进同一张集合、按四邻连接取字形，所以 T / 十字是跨 panel 算出来的。

(provide (all-from-out "rect.rkt" "panel.rkt"))

(require "rect.rkt"
         "panel.rkt")

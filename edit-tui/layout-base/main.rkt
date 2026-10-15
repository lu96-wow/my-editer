#lang racket

;;; edit-tui/layout-base/main.rkt —— 布局层入口（只做再导出）
;;;
;;; 分成三层：
;;;   rect     矩形算术（唯一几何值）
;;;   panel    面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face + 内容区 + 命中
;;;   region   区域树 + 布局原语（split / remove / resize / rescale / 投影）
;;;
;;; 边框的**画**（字形 / face / pane）在 core-render/border.rkt。

(provide (all-from-out "rect.rkt" "panel.rkt" "region.rkt"))

(require "rect.rkt"
         "panel.rkt"
         "region.rkt")

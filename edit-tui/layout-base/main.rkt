#lang racket

;;; edit-tui/layout-base/main.rkt —— 布局层入口（只做再导出）
;;;
;;; 分成四块：
;;;   rect     矩形算术（唯一几何值）
;;;   panel    面板：外框矩形 + 四条边可选边框 + 深度 + 边框 face + 内容区 + 命中
;;;   border   面板边框 → 装饰 pane：跨 panel 收集边、按同向延续取字形、合成 run
;;;   render   布局边框 → tui 序列：把 border-run 直接画成可 put-bytes 的字节
;;;
;;; 边框只认 panel 的几何（rect / borders / deep / face），不碰 core 的渲染值（piece）。
;;; border.rkt 出 pane（交给 core 合成，可跟内容分层遮挡）；render.rkt 出 tui 序列
;;; （直接输出，border-only）。两者对称于 core-render：数据在 core，序列化在各层。

(provide (all-from-out "rect.rkt" "panel.rkt" "border.rkt" "render.rkt"))

(require "rect.rkt"
         "panel.rkt"
         "border.rkt"
         "render.rkt")

#lang racket

;;; edit/layout.rkt —— 布局层入口（只做再导出）
;;;
;;; 布局 = 一堆面板（panel）：外框矩形 + 四条边可选边框 + 深度。不必布满屏幕。
;;; 提供：矩形算术、取内容区、命中、面板 → display-entry、边框 → 装饰 pane。

(provide (all-from-out "layout/rect.rkt"
                       "layout/panel.rkt"
                       "layout/border.rkt"))

(require "layout/rect.rkt"
         "layout/panel.rkt"
         "layout/border.rkt")

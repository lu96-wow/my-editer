#lang racket

;;; edit/core-render/main.rkt —— 渲染后端入口（统一）
;;;
;;; 一个后端，负责把 core 的渲染值画成 tui 序列：
;;;   · core 的渲染值（piece）→ render.rkt
;;; 只产出序列，不自己输出；颜色统一由 theme 解析。
;;;
;;; 布局边框（panel → pane）不在这里 —— 在 layout-base/border.rkt。
;;; face 值（生产者/消费者共用）在 base/face.rkt。

(provide (all-from-out "../base/face.rkt"
                       "render.rkt"))

(require "../base/face.rkt"
         "render.rkt")

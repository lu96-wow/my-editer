#lang racket

;;; edit/core-render/main.rkt —— 渲染后端入口（统一）
;;;
;;; 一个后端，负责把「可绘制数据」画成 tui 序列：
;;;   · core 的渲染值（piece）→ render.rkt
;;;   · 布局的边框（panel）→ border.rkt
;;; 两者都只产出数据 / 序列，不自己输出；颜色统一由 theme 解析。
;;;
;;; face 值（生产者/消费者共用）在 base/face.rkt。

(provide (all-from-out "../base/face.rkt"
                       "render.rkt"
                       "border.rkt"))

(require "../base/face.rkt"
         "render.rkt"
         "border.rkt")

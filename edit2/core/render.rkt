#lang racket

;;; edit2/render.rkt —— 渲染投影（core 合成）
;;;
;;;   render : State [Placement] Size OldScreen -> (values Screen render-pieces selection-pieces)
;;;
;;; 布局是纯函数（layout.rkt）；合成交给 core：placements → rectangle → patch。
;;; 浮窗靠 z（deep）叠在平铺之上；谁接键由 state.focus / stack 决定（不在渲染层）。

(provide render)

(require "state.rkt" "layout.rkt" "adapter.rkt")

(define (render st placements size old)
  (define w (car size))
  (define h (cdr size))
  (render-layout (state-ed st) placements (state-focus st) w h old))


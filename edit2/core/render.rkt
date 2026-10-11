#lang racket

;;; edit2/render.rkt —— 渲染投影（core 合成）
;;;
;;;   render : State [Placement] Size OldScreen -> (values Screen render-pieces selection-pieces)
;;;
;;; 布局是纯函数（layout.rkt）；合成交给 core：placements → rectangle → patch。
;;; 浮窗靠 z（deep）叠在平铺之上；谁接键由 state.focus / stack 决定（不在渲染层）。
;;;
;;; 尺寸归属：viewport 是 view 的状态，core 的 editor-set-layout! 逐个 rectangle 把 w/h
;;; 写回 view（同 view 多窗口时最后写入的为准，锚点保持）。所以**以焦点窗口为准**：
;;; 把焦点窗口的 placement 排到最后，view 的尺寸就取当前（正在编辑的）窗口。

(provide render)

(require "state.rkt" "layout.rkt" "adapter.rkt")

(define (render st placements size old)
  (define w (car size))
  (define h (cdr size))
  (define focus (state-focus st))
  ;; focus 是 wid；core 的 active 要 vid（同 view 多位置时各窗格都会透出光标）。
  (define active (layout-wid-vid (state-layout st) focus))
  (define ordered
    (sort placements
          (lambda (a b)
            (define (rank p) (if (eqv? focus (placement-wid p)) 1 0))
            (< (rank a) (rank b)))))
  (render-layout (state-ed st) ordered active w h old))

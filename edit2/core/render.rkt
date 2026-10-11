#lang racket

;;; edit2/render.rkt —— 渲染投影（core 合成）
;;;
;;;   render : State [Placement] Size OldScreen -> (values Screen render-pieces selection-pieces)
;;;
;;; 布局是纯函数（layout.rkt）；边框是原子格组合（border.rkt）；合成交给 core。
;;;
;;; 尺寸归属：viewport 是 view 的状态，core 的 editor-set-layout! 逐个 rectangle 把 w/h
;;; 写回 view（同 view 多窗口时最后写入的为准，锚点保持）。所以**以焦点窗口为准**：
;;; 把焦点窗口的 content placement 排到最后，view 的尺寸就取当前窗口。
;;;
;;; 边框：内容内缩 1 格，边框作为装饰 pane 叠在上面；重合/共享边已由 border-plan 合并。

(provide render)

(require "state.rkt" "layout.rkt" "border.rkt" "adapter.rkt")

(define (render st placements size old)
  (define w (car size))
  (define h (cdr size))
  (define focus (state-focus st))
  ;; focus 是 wid；core 的 active 要 vid（只显示焦点那个 view 的光标，空窗口 → #f）。
  (define active (layout-wid-vid (state-layout st) focus))
  (define-values (content borders) (border-plan (state-layout st) placements))
  (define ordered
    (sort content
          (lambda (a b)
            (define (rank p) (if (eqv? focus (placement-wid p)) 1 0))
            (< (rank a) (rank b)))))
  (define brs
    (for/list ([b (in-list borders)])
      (list (border-run-row b) (border-run-col b) (border-run-text b) (border-run-face b))))
  (render-layout (state-ed st) ordered active w h old brs))

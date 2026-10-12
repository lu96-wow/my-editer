#lang racket

;;; edit4/view/render.rkt —— frame → 屏幕
;;;
;;; 把 frame（平铺矩形 + 浮窗矩形）按「窗口 id → vid」绑定成 core rectangle，
;;; 再交给引擎做增量 patch；装饰层（缝/浮窗框）由 border.rkt 提供。
;;; 渲染只读 World/frame，不改状态。

(provide frame->rectangles render-frame)

(require racket/list
         "../layout.rkt"
         "../content/adapter.rkt"
         "border.rkt")

;; frame -> (listof rectangle)；deep 分层：平铺 0，浮窗 2·z（表头最上）。
(define (frame->rectangles fr id->vid)
  (define tiled
    (for/list ([(id r) (in-hash (geometry-rects (frame-tiled fr)))] #:when (id->vid id))
      (rectangle (id->vid id) (rect-x r) (rect-y r) (rect-w r) (rect-h r) 0)))
  (define fs (frame-float-rects fr))
  (define n (length fs))
  (define floats
    (for/list ([p (in-list fs)] [i (in-naturals)] #:when (id->vid (car p)))
      (define r (cdr p))
      (rectangle (id->vid (car p)) (rect-x r) (rect-y r) (rect-w r) (rect-h r) (* 2 (- n i)))))
  (append tiled floats))

;; render-frame : ed frame id->vid active-vid w h old -> (values screen rends sels)
(define (render-frame ed fr id->vid active-vid w h old)
  (render-layout ed (frame->rectangles fr id->vid) active-vid w h old (border-runs fr)))

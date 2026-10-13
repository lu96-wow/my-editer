#lang racket

;;; edit4/layout/frame.rkt —— 一帧的完整几何（平铺 + 浮窗）+ 统一定序命中
;;;
;;; frame = 平铺几何（矩形+cuts） + 浮窗矩形（表头在前）。
;;; hit-frame 按 z 统一：先浮窗（最上），再平铺的 cut / pane。
;;; 于是「渲染/命中/z 序」只在这里体现一次。

(provide (struct-out frame)
         (struct-out pane-target) (struct-out seam-target) (struct-out float-target)
         hit-frame frame-rel-rect frame-float-rect frame-float-content-rect frame-with-tiled)

(require "rect.rkt" "geometry.rkt" "float.rkt" "hit.rkt" racket/list)

(struct frame (tiled float-rects w h) #:transparent)
;; tiled       : geometry（tiled 几何）
;; float-rects : (listof (cons float-id rect))，表头在前 = 最上

;; frame-with-tiled : tiled floats size -> frame
;;   平铺几何算好后，叠上浮窗矩形——组装一帧的唯一入口（cache / 钩子共用）。
(define (frame-with-tiled tiled floats size)
  (define area (rect 0 0 (car size) (cdr size)))
  (frame tiled (place-floats (geometry-rects tiled) floats area) (car size) (cdr size)))

(struct pane-target  (id)     #:transparent)
(struct seam-target  (cuts)   #:transparent)
(struct float-target (id action) #:transparent)   ; action = move | nw | ne | sw | se

;; 统一命中：浮窗优先（z），否则平铺的缝 / 内容。
(define (hit-frame fr x y)
  (define fh (float-hit (frame-float-rects fr) x y))
  (cond
    [fh (float-target (car fh) (cadr fh))]
    [else
     (define t (hit (frame-tiled fr) x y))
     (cond
       [(not t) #f]
       [(list? t) (seam-target t)]          ; 平铺 hit 返回 cut 列表
       [else (pane-target t)])]))           ; 或 pane id

(define (frame-rel-rect fr f)
  (resolve-anchor-rel (anchor-rel (float-anchor f))
                      (geometry-rects (frame-tiled fr))
                      (rect 0 0 (frame-w fr) (frame-h fr))))

(define (frame-float-rect fr id)
  (for/first ([p (in-list (frame-float-rects fr))] #:when (eqv? id (car p))) (cdr p)))

;; 浮窗内容矩形（外框内缩 1）；渲染 / 点击→文档点用它，命中 / 移动用外框。
(define (frame-float-content-rect fr id)
  (define r (frame-float-rect fr id))
  (and r (float-content-rect r)))

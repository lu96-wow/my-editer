#lang racket

;;; edit4/layout/cache.rkt —— 几何缓存（按输入身份失效）
;;;
;;; geometry = f(tiling, floats, size)。只要这三个输入没变，输出逐字节相同。
;;; 输入用 `eq?`（持久化结构没动过 → 同一个根对象）+ size 用 `equal?`。
;;;
;;; 两级：
;;;   · 平铺几何只依赖 (tiling, size)；
;;;   · 浮窗矩形依赖 (floats, 平铺矩形, size) —— 拖浮窗时平铺那级不动。
;;;
;;; 产出 frame（平铺 + 浮窗），交给渲染与命中。

(provide (struct-out layout-cache) empty-layout-cache
         ensure-tiled ensure-layout)

(require "rect.rkt" "geometry.rkt" "float.rkt" "frame.rkt")

(struct layout-cache (tiling size tiled            ; 平铺级
                      floats f-tiled f-size frame) ; 浮窗级（frame 缓存）
  #:transparent)

(define empty-layout-cache (layout-cache #f #f #f #f #f #f #f))

(define (area-of size) (rect 0 0 (car size) (cdr size)))

;; ensure-tiled : cache tiling size -> (values cache tiled-geometry)
(define (ensure-tiled cache tiling size)
  (cond
    [(and (eq? tiling (layout-cache-tiling cache))
          (equal? size (layout-cache-size cache))
          (layout-cache-tiled cache))
     (values cache (layout-cache-tiled cache))]
    [else
     (define t (layout tiling (area-of size)))
     (values (struct-copy layout-cache cache
                          [tiling tiling] [size size] [tiled t])
             t)]))

;; ensure-layout : cache tiling floats size -> (values cache frame)
(define (ensure-layout cache tiling floats size)
  (define-values (cache1 tiled) (ensure-tiled cache tiling size))
  (cond
    [(and (eq? floats (layout-cache-floats cache1))
          (eq? tiled (layout-cache-f-tiled cache1))
          (equal? size (layout-cache-f-size cache1))
          (layout-cache-frame cache1))
     (values cache1 (layout-cache-frame cache1))]
    [else
     (define fr (frame-with-tiled tiled floats size))
     (values (struct-copy layout-cache cache1
                          [floats floats] [f-tiled tiled] [f-size size] [frame fr])
             fr)]))

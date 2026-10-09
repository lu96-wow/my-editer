#lang racket

;;; edit/area.rkt —— 矩形区域（屏幕坐标）与切分
;;;
;;; 布局核心（edit/layout.rkt）和编辑区布局共用同一个 area 类型与切分原语。

(provide (struct-out area) area-split)

(struct area (x y w h) #:transparent)

;; 按轴切：dir = 'lr（左 first 右 rest）| 'tb（上 first 下 rest）。
(define (area-split a dir size)
  (case dir
    [(lr) (values (area (area-x a) (area-y a) size (area-h a))
                  (area (+ (area-x a) size) (area-y a) (- (area-w a) size) (area-h a)))]
    [(tb) (values (area (area-x a) (area-y a) (area-w a) size)
                  (area (area-x a) (+ (area-y a) size) (area-w a) (- (area-h a) size)))]
    [else (error 'area-split "dir 必须是 'lr / 'tb，得到 ~a" dir)]))

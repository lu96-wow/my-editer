#lang racket

;;; edit/geometry/place.rkt —— 布局求值 + 缓存（纯）
;;;
;;; 局部问题：把「布局树 + 显隐 + 屏幕区域」求值成已落位的视图（placed），
;;; 并在输入没变时复用上一次结果。
;;;
;;; 求值本身是 core/layout 的 layout-place（纯树遍历）；这里只加一层缓存：
;;; 缓存键相等 → 复用；不等 → 重算。缓存实体放在可变的 runtime 里，
;;; 每帧把 key 传进来比对即可（几何不必每帧重算）。
;;;
;;; 只认识「键」和「结果」，不认识 session / editor。

(provide (struct-out place-cache) place-cache-refresh place-cache-stale?)

(struct place-cache (key placed) #:transparent)
;; key    : any/c                缓存键（如 (list 布局树 显隐表 宽 高)）
;; placed : (listof placed)      上次求值结果

(define (place-cache-stale? old key)
  (or (not old) (not (equal? key (place-cache-key old)))))

;; 旧缓存 + 本次键 + 求值过程 → 缓存（命中则原样返回旧值）。
(define (place-cache-refresh old key compute)
  (if (place-cache-stale? old key)
      (place-cache key (compute))
      old))

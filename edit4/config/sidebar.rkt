#lang racket

;;; edit4/config/sidebar.rkt —— 侧栏（文件树 dock）尺寸策略（纯数据 + 纯函数）
;;;
;;; dock 是固定尺寸的窗格（size elastic? = #f）：启动时算一次，之后运行时改窗口大小
;;; 不再影响它（固定项不参与等比缩放，basis 保持）。
;;;
;;; 朝向决定用哪套：
;;;   left / right  → 宽度（占屏宽比例，夹 [min-width, max-width]）
;;;   top / bottom  → 高度（占屏高比例，夹 [min-height, max-height]）
;;; boot 对 size/min 为 auto 的 dock 按 side 取对应值（见 boot.rkt 的 dock-dim）。

(provide sidebar-ratio sidebar-min-width sidebar-max-width sidebar-width
         sidebar-height-ratio sidebar-min-height sidebar-max-height sidebar-height)

(define sidebar-ratio 1/4)      ; 横向：屏宽的 1/4
(define sidebar-min-width 5)    ; 至少 5 列
(define sidebar-max-width 30)   ; 最多 30 列

(define sidebar-height-ratio 1/3)   ; 纵向：屏高的 1/3
(define sidebar-min-height 4)       ; 至少 4 行
(define sidebar-max-height 12)      ; 最多 12 行

;; 屏幕宽度 -> 横向 dock 宽度：按比例取最近整数，夹在 [min, max]。
(define (sidebar-width screen-width)
  (min sidebar-max-width
       (max sidebar-min-width
            (round (* sidebar-ratio screen-width)))))

;; 屏幕高度 -> 纵向 dock 高度：按比例取最近整数，夹在 [min, max]。
(define (sidebar-height screen-height)
  (min sidebar-max-height
       (max sidebar-min-height
            (round (* sidebar-height-ratio screen-height)))))

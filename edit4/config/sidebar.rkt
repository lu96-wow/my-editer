#lang racket

;;; edit4/config/sidebar.rkt —— 文件树（侧栏）宽度策略（纯数据 + 纯函数）
;;;
;;; 侧栏是固定宽度的窗格（size elastic? = #f）：启动时按屏幕宽度算一次，之后运行时
;;; 改窗口大小不再影响它（固定项不参与等比缩放，basis 保持）。
;;;
;;;   ratio : 期望宽度占屏宽的比例
;;;   min   : 下限（再窄也保留）
;;;   max   : 上限（避免占满屏幕）

(provide sidebar-ratio sidebar-min-width sidebar-max-width sidebar-width)

(define sidebar-ratio 1/4)      ; 屏宽的 1/4
(define sidebar-min-width 5)    ; 至少 5 列
(define sidebar-max-width 30)   ; 最多 30 列

;; 屏幕宽度 -> 侧栏宽度：按比例取最近整数，夹在 [min, max]。
(define (sidebar-width screen-width)
  (min sidebar-max-width
       (max sidebar-min-width
            (round (* sidebar-ratio screen-width)))))

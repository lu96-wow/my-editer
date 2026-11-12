#lang racket

;;; edit-tui/core/api.rkt —— 纯数据 / 算法面
;;;
;;; 这一层只导出值和纯函数：document / view / panel / rect / screen /
;;; change / selection / point / range，以及命令表 / 键 token。
;;;
;;; 不导出：engine、hook、插件、IO、事件循环。
;;;
;;; 第一阶段直接复用 repo 的 core 实现；以后如果需要把 core 也搬进来，
;;; 只改这里，外部的 editor / plugins 不受影响。

(require "../../core/editor.rkt"
         "command/api.rkt")

(provide (all-from-out "../../core/editor.rkt"
                       "command/api.rkt"))

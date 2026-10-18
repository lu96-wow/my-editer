#lang racket

;;; layer  : theme
;;; effect : 安装样式表（require 即副作用）

;;; edit-tui/theme/main.rkt —— 主题入口：require 即安装
;;;
;;; 顶层直接 define-theme!：这个模块被 require 时就把默认主题写进 racket-tui 的
;;; 样式表（style-define! 只写 hash，不需要终端），宿主不用再手动 install。
;;;
;;; 想要自定义 / 覆盖：require 之后再 (define-theme! …) 即可（同名覆盖）。
;;; 数据也可以只取一份：theme/core.rkt、theme/frame.rkt。

(require "theme.rkt"
         "core.rkt"
         "frame.rkt")

;; 顶层副作用：require 即装（core + frame）。
(define-theme! (append core-theme frame-theme))

(provide (all-from-out "theme.rkt"
                       "core.rkt"
                       "frame.rkt"))

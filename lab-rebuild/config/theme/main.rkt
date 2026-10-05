#lang racket

(require "theme.rkt"
         "dark.rkt"
         "light.rkt")

;;; lab-rebuild/config/theme/main.rkt —— 主题汇总 + 当前主题
;;;
;;; 后端每帧读 `(current-theme)`；要换主题就 `(current-theme light-theme)`。
;;; `current-theme` 是**可配置状态**：运行时可改，不必重编译。

(provide (all-from-out "theme.rkt")
         (all-from-out "dark.rkt")
         (all-from-out "light.rkt")
         current-theme)

(define current-theme (make-parameter dark-theme))

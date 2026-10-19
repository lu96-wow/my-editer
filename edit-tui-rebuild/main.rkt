#lang racket

;;; edit-tui-rebuild/main.rkt —— 公共入口
;;; 统一从 api/main.rkt 导出。

(require "api/main.rkt")
(provide (all-from-out "api/main.rkt"))

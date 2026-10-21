#lang racket

;;; edit-tui-rebuild/config/keymap/buffer.rkt —— buffer 创建时的键表选择
;;;
;;; 兼容入口：键表现在是 buffer-mode 的一部分，选择逻辑在 config/mode.rkt。
;;; 新代码应直接使用 buffer-mode-for-creation / buffer-mode-key-table。

(require "../mode.rkt")

(provide buffer-key-table
         racket-buffer-key-table
         text-buffer-key-table)

#lang racket

;;; edit-tui/core/command/mode.rkt —— 持久命令模式
;;;
;;; mode-command 是命令表里的一个普通值：
;;;   (mode-command id table)
;;;
;;; 执行后 host 进入该 table 的独占键盘模式；表里的命令可以连续执行，
;;; 直到执行 mode-exit-command。模式表仍是普通 command-table，可以继续
;;; 包含前缀命令，也可以嵌套另一个 mode-command。
;;;
;;; 这里只定义纯值；模式状态、dispatch 优先级和插件 owner 归一化由
;;; editor / host 处理。

(require "table.rkt")

(provide (struct-out mode-command)
         make-mode-command
         (struct-out mode-exit-command))

(struct mode-command (id table) #:transparent)

(define (make-mode-command id table)
  (unless (symbol? id)
    (raise-argument-error 'make-mode-command "symbol?" id))
  (unless (command-table? table)
    (raise-argument-error 'make-mode-command "command-table?" table))
  (mode-command id table))

(struct mode-exit-command () #:transparent)

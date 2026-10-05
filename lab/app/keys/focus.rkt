#lang racket

(require "../commands.rkt"
         "../../base/input.rkt"
         "../../base/command.rkt")

;;; lab/app/keys/focus.rkt —— 焦点移动键（C-p 前缀下的默认表）
;;;
;;; 终端里 Ctrl+↑/↓ 常被吞（VTE 直接丢），所以用前缀键：
;;;   C-p 然后 left/right/up/down → 移焦点
;;; C-p 是普通控制字节 0x10，方向键无修饰，任何终端都送得到。

(provide focus-keys)

(define focus-keys
  (command-table
   (key 'left)   cmd-focus-left
   (key 'right)  cmd-focus-right
   (key 'up)     cmd-focus-up
   (key 'down)   cmd-focus-down
   (key 'escape) cmd-noop))    ; 退出前缀（app 会自动清）

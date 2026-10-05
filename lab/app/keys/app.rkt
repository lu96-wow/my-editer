#lang racket

(require "../commands.rkt"
         "focus.rkt"
         "../../base/input.rkt"
         "../../base/command.rkt")

;;; lab/app/keys/app.rkt —— app 级全局键（对所有文档生效）

(provide app-keys)

(define app-keys
  (command-table
   (key 'q 'ctrl) cmd-quit
   (key 'o 'ctrl) cmd-toggle-focus
   (key 'p 'ctrl) (cmd-prefix "C-p" (list focus-keys))   ; 前缀：移焦点
   (key 's 'ctrl) cmd-save
   ;; 编辑区分屏：K 水平（上下）/ L 垂直（左右）分隔，D 关窗格
   (key 'k 'ctrl) cmd-split-tb
   (key 'l 'ctrl) cmd-split-lr
   (key 'd 'ctrl) cmd-pane-close))

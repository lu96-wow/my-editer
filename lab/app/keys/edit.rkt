#lang racket

(require "../commands.rkt"
         "../../base/input.rkt"
         "../../base/command.rkt")

;;; lab/app/keys/edit.rkt —— 编辑键（对所有文档生效）
;;;
;;; 纯数据：binding → 命令（命令见 app/commands.rkt）。不含任何动作代码。

(provide edit-keys)

(define edit-keys
  (command-table
   text-binding        cmd-insert
   (key 'enter)        cmd-newline
   (key 'tab)          cmd-tab
   (key 'backspace)    cmd-backspace
   (key 'delete)       cmd-delete
   (key 'left)         cmd-left
   (key 'right)        cmd-right
   (key 'up)           cmd-up
   (key 'down)         cmd-down
   (key 'home)         cmd-home
   (key 'end)          cmd-end
   (key 'left 'shift)  cmd-left-select
   (key 'right 'shift) cmd-right-select
   (key 'up 'shift)    cmd-up-select
   (key 'down 'shift)  cmd-down-select
   (key 'home 'shift)  cmd-home-select
   (key 'end 'shift)   cmd-end-select
   (key 'a 'ctrl)      cmd-select-all
   (key 'c 'ctrl)      cmd-copy
   (key 'x 'ctrl)      cmd-cut
   (key 'v 'ctrl)      cmd-paste
   (key 'z 'ctrl)      cmd-undo
   (key 'y 'ctrl)      cmd-redo))

#lang racket

(require "../commands.rkt"
         "readonly.rkt"
         "../../base/input.rkt"
         "../../base/command.rkt")

;;; lab/app/keys/bufs.rkt —— 文档 / 视图列表面板键（覆盖只读基表）

(provide bufs-keys)

(define bufs-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)       cmd-bufs-toggle-left
          (key 'enter)     cmd-bufs-activate
          (key 'n 'ctrl)   cmd-bufs-new-view
          (key 'backspace) cmd-bufs-close))))

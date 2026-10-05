#lang racket

(require "../commands.rkt"
         "readonly.rkt"
         "../../base/input.rkt"
         "../../base/command.rkt")

;;; lab/app/keys/tree.rkt —— 文件树面板键（覆盖只读基表）

(provide tree-keys)

(define tree-keys
  (command-merge
   (list readonly-keys
         (command-table
          (key 'tab)       cmd-tree-toggle-left
          (key 'enter)     cmd-tree-activate
          (key 'n 'ctrl)   cmd-tree-new-file
          (key 'l 'ctrl)   cmd-tree-new-dir
          (key 'backspace) cmd-tree-delete))))

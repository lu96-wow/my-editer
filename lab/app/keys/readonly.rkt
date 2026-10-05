#lang racket

(require "../commands.rkt"
         "../../base/input.rkt"
         "../../base/command.rkt")

;;; lab/app/keys/readonly.rkt —— 只读面板基表（吞掉所有编辑键）
;;;
;;; 文件树 / 文档列表 / 确认型模态都叠在它上面。

(provide readonly-keys)

(define readonly-keys
  (command-table
   text-binding     cmd-noop
   (key 'enter)     cmd-noop
   (key 'tab)       cmd-noop
   (key 'backspace) cmd-noop
   (key 'delete)    cmd-noop
   (key 'v 'ctrl)   cmd-noop
   (key 'x 'ctrl)   cmd-noop
   (key 'z 'ctrl)   cmd-noop
   (key 'y 'ctrl)   cmd-noop))

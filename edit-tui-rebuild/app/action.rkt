#lang racket

;;; edit-tui-rebuild/app/action.rkt —— step 产生的 action 数据
;;;
;;; resource-action 由 resource 模块产生；这里只补 view / quit。
;;; action 不是通用 effect 系统：runtime 直接按 kind 解释。

(provide (struct-out view-action)
         (struct-out quit-action))

(struct view-action (kind view-id data) #:transparent)
;; kind : 'insert | 'nav | 'select | 'scroll | 'ensure | 'undo | 'redo

(struct quit-action () #:transparent)

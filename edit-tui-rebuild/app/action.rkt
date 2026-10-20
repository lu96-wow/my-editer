#lang racket

;;; edit-tui-rebuild/app/action.rkt —— step 产生的 action 数据
;;;
;;; resource-action 由 resource 模块产生；这里只补 view / quit。
;;; action 不是通用 effect 系统：runtime 直接按 kind 解释。

(provide (struct-out view-action)
         (struct-out open-file-action)
         (struct-out quit-action))

(struct view-action (kind view-id data) #:transparent)
;; kind : 'insert | 'paste | 'backspace | 'delete | 'kill-line
;;      | 'nav | 'point | 'select | 'scroll | 'ensure | 'undo | 'redo
;;
;; data :
;;   insert/paste      文本
;;   nav               dir | (list dir extend?)
;;   point             (list row col)（相对内容区，0 基）
;;   select            core selections 值
;;   scroll            number | 'page-up | 'page-down
;;   其余              #f

;; 文件树打开文件：runtime 读盘 -> resource-open -> 进入 placement。
(struct open-file-action (path tables) #:transparent)

(struct quit-action () #:transparent)

#lang racket

;;; edit-tui-rebuild/app/action.rkt —— step 产生的 action 数据
;;;
;;; resource-action 由 resource 模块产生；view-action 在骨架层
;;; (engine/action.rkt)；这里只补 application 级的 open-file / quit。
;;; action 不是通用 effect 系统：runtime 直接按 kind 解释。

(require "../skeleton/api.rkt")

(provide (struct-out view-action)
         (struct-out open-file-action)
         (struct-out quit-action))

;; 文件树打开文件：runtime 读盘 -> resource-open -> 进入 placement。
(struct open-file-action (path tables) #:transparent)

(struct quit-action () #:transparent)

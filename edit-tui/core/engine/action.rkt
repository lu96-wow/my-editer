#lang racket

;;; edit-tui-rebuild/engine/action.rkt —— 骨架层的 view 操作 action
;;;
;;; engine 只认这一种 action：对某个 view 做 insert / nav / select / scroll …
;;; open-file / quit 这类应用级 action 在 app/action.rkt。
;;;
;;; engine 按 kind 解释，data 形状见下；不是通用 effect 系统。

(provide (struct-out view-action))

(struct view-action (kind view-id data) #:transparent)
;; kind : 'insert | 'paste | 'backspace | 'delete | 'kill-line
;;      | 'nav | 'point | 'select | 'scroll | 'ensure | 'undo | 'redo
;;

;; data :
;;   insert/paste      原始 UTF-8 bytes（engine 写 buffer 时解码一次）
;;   nav               dir | (list dir extend?)
;;   point             (list row col) | (list row col extend?)
;;                     （相对内容区，0 基；越界夹到最近有效位置）
;;                     extend? = #t：保留选区 anchor，只移动 head（鼠标拖选）
;;   select            core selections 值
;;   scroll            number | 'page-up | 'page-down
;;   其余              #f

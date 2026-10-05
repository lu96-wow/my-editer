#lang racket

(require "../commands.rkt"
         "readonly.rkt"
         "../../base/input.rkt"
         "../../base/command.rkt")

;;; lab/app/keys/modal.rkt —— 模态表（dispatch 时叠在最上层）
;;;
;;; input-edit-keys  输入型：enter 提交、escape 取消、tab 吞掉；
;;;                  字符 / 退格落全局 edit-keys（本表不绑 → 回落）。
;;; confirm-keys     确认型：y / n 收 bool，其余吞掉。

(provide input-edit-keys confirm-keys)

(define input-edit-keys
  (command-table
   (key 'enter)  cmd-commit
   (key 'escape) cmd-cancel
   (key 'tab)    cmd-noop))

(define confirm-keys
  (command-merge
   (list readonly-keys
         (command-table
          text-binding  cmd-answer
          (key 'escape) cmd-cancel))))

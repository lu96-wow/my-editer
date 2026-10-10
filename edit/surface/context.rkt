#lang racket

;;; edit/surface/context.rkt —— 输入上下文（纯）
;;;
;;; 局部问题：此刻**哪些键表生效、按什么顺序查**。
;;; 上下文 = 一叠键表（栈顶在前）：
;;;
;;;     模态层（补全 / 文档窗） → 焦点面键表 → 文档键表 → 全局
;;;
;;; 查找自上而下，第一个命中的赢；都落空 → #f（不处理，回落到下一层）。
;;; 后端只需把事件解码成绑定键，交给这里；命中即得 spec（cmd / prefix / 过程）。
;;;
;;; 只认识键表与绑定键，不认识 session。

(require "../core/keymap.rkt")

(provide context-lookup)

;; kms : (listof keymap)   栈顶在前
;; b   : binding | #f
(define (context-lookup kms b)
  (and b
       (for/or ([km (in-list kms)]) (keymap-lookup km b))))

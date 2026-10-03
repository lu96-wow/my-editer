#lang racket

;;; lab/command/base.rkt —— 命令层基础类型
;;;
;;;   binding  绑定键：物理键名 + 修饰键（鼠标/滚轮不进表，由派发层通用处理）
;;;   command  命令：名字 + 过程 (session × ctx × input → (values session effects))
;;;   context  派发上下文：当前屏幕格数（鼠标命中、翻页等用）
;;;
;;; 命令表的值是 command；每文档表覆盖默认表，未命中的回落到默认表。

(require "../input.rkt")

(provide
 (struct-out binding)
 (struct-out command)
 (struct-out context)
 make-command
 input->binding)

;; 绑定键：name 是 char 或命名键 symbol；mods 是 modifiers。
(struct binding (name mods) #:transparent)

;; 派发上下文。
(struct context (rows cols) #:transparent)

;; 命令：proc : session ctx input -> (values session (listof effect))
(struct command (name proc) #:transparent)

(define (make-command name proc) (command name proc))

;; input → binding（只有 key 进表；其余 → #f，交给派发层的通用处理）。
(define (input->binding in)
  (match in
    [(key name mods) (binding name mods)]
    [_ #f]))

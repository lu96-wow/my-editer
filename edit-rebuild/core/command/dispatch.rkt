#lang racket

;;; edit-rebuild/core/command/dispatch.rkt —— 事件 → 命令 → 会话
;;;
;;; 局部问题：把后端解出的一「输入」翻译成命令并执行。
;;; 后端（backend/tui.rkt）只负责把终端事件解成 input（绑定键 + 载荷）；
;;; 前缀 / 上下文键表 / spec→cmd / step 都在这里，后端不认识命令。
;;;
;;;   input = (binding text cols rows col row)
;;;   resolve : session input -> cmd | #f
;;;   dispatch : session input -> session

(require "command.rkt"
         "key.rkt"
         "../keymap.rkt"
         "../session/session.rkt"
         "../session/context.rkt")

(provide (struct-out input) resolve dispatch)

(struct input (binding text cols rows col row) #:transparent)
;; binding : 绑定键 | #f
;; text    : string | #f       文本通道载荷
;; cols rows : integer | #f    resize 载荷
;; col row : integer | #f      mouse 载荷

;; 后端给的 spec 标记 / cmd / prefix → 具体命令。
(define (spec->cmd spec in)
  (cond
    [(prefix? spec) (cmd-prefix spec)]
    [(eq? spec text-spec) (cmd-insert (or (input-text in) ""))]
    [(eq? spec resize-spec) (cmd-resize (input-cols in) (input-rows in))]
    [(eq? spec mouse-press-spec) (cmd-mouse-press (input-col in) (input-row in))]
    [(eq? spec mouse-scroll-up-spec) (cmd-mouse-scroll (input-col in) (input-row in) -1)]
    [(eq? spec mouse-scroll-down-spec) (cmd-mouse-scroll (input-col in) (input-row in) 1)]
    [(procedure? spec) (spec in)]
    [else spec]))

(define (resolve s in)
  (define b (input-binding in))
  (define pfx (session-prefix s))
  (cond
    ;; 前缀激活：只在当前前缀键表里查；未命中则取消。
    [pfx
     (define spec (and b (keymap-lookup (prefix-keymap pfx) b)))
     (cond [spec (spec->cmd spec in)]
           [else (cmd-prefix-cancel)])]
    [else
     (define spec (keymap-stack-lookup (session-context-keys s) b))
     (and spec (spec->cmd spec in))]))

(define (dispatch s in)
  (define c (resolve s in))
  (if c (step s c) s))

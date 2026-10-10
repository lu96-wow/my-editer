#lang racket

;;; edit/session/context.rkt —— 输入上下文：从会话取出此刻生效的键表栈
;;;
;;; 局部问题：把「此刻该查哪些键表」从后端（tui）里搬出来，集中一处。
;;; 栈序（先命中先赢）：
;;;
;;;     模态层（补全 / 文档） → 焦点面的键表 → 文档键表 → 全局
;;;
;;; 纯查表在 surface/context.rkt；本模块只负责从会话取值拼栈。

(require "value.rkt"
         "core.rkt"
         "doc.rkt"
         "../surface/surface.rkt")

(provide session-context-keys)

;; → (listof keymap)   栈顶在前
(define (session-context-keys s)
  (define vid (session-focus-vid s))
  (define did (session-focused-did s))
  (append
   ;; 浮动面的键（模态优先，如补全菜单；面在即生效）
   (for/list ([sf (in-list (session-surfaces s))] #:when (surface-keys sf))
     (surface-keys sf))
   (filter values (list (and vid (session-vid-keys s vid))
                        (and did (session-doc-keys s did))))
   (session-keys s)))

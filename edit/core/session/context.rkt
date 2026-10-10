#lang racket

;;; edit-rebuild/core/session/context.rkt —— 输入上下文：从会话取出此刻生效的键表栈
;;;
;;; 局部问题：把「此刻该查哪些键表」从后端搬出来，集中一处。
;;; 栈序（先命中先赢）：
;;;
;;;     浮面的键（模态，如在补全菜单） → 焦点面键表 → 文档键表 → 全局
;;;
;;; 纯查表在 surface/context.rkt；这里只负责从会话取值拼栈。

(require "session.rkt"
         "adapter.rkt"
         "../surface/surface.rkt")

(provide session-context-keys)

(define (session-context-keys s)
  (define vid (session-focus-vid s))
  (define did (session-focused-did s))
  (append
   ;; 只有**浮动**面的键是模态的（面在即生效，如补全菜单）；停靠面按焦点取。
   (for/list ([sf (in-list (session-surfaces s))]
              #:when (and (surface-float? sf) (surface-keys sf)))
     (surface-keys sf))
   (filter values (list (and vid (session-vid-keys s vid))
                        (and did (hash-ref (session-doc-keymaps s) did #f))))
   (session-keys s)))

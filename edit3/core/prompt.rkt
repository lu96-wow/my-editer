#lang racket

;;; edit3/prompt.rkt —— 输入行**语义注册表**：kind -> handler（由 edit2 平移）
;;;
;;; core 注册一批基础 kind（见 step.rkt base-prompt-kinds），插件用
;;; prompt-kind-register 加自己的 kind。
;;;
;;; handler : st prompt text -> (values state (listof effect))
;;; 注册表是纯值，可组合、可测：扩展 = 返回一张新表。

(provide (struct-out prompt-kind-registry)
         make-prompt-kind-registry prompt-kind-register prompt-kind-lookup)

(struct prompt-kind-registry (handlers) #:transparent)   ; hash : kind -> handler

;; entries : (listof (cons kind handler))
(define (make-prompt-kind-registry entries)
  (prompt-kind-registry (for/hash ([e (in-list entries)]) (values (car e) (cdr e)))))

(define (prompt-kind-register reg kind handler)
  (prompt-kind-registry (hash-set (prompt-kind-registry-handlers reg) kind handler)))

(define (prompt-kind-lookup reg kind)
  (hash-ref (prompt-kind-registry-handlers reg) kind #f))

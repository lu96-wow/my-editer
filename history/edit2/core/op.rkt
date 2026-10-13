#lang racket

;;; core/op.rkt —— 原语**注册表**：tag -> handler
;;;
;;; 取代原来 run-op 里那个封闭的 case：core 注册一批基础原语（见 step.rkt
;;; base-op-registry），插件用 op-register 往上加自己的原语。
;;;
;;; handler : ctx st ev args -> (values state (listof effect))，args = (cdr op)。
;;; 未知 tag → 原样返回（和原来 case 的 else 一致，不报错）。
;;;
;;; 注册表是**纯值**（不搞全局可变表），可组合、可测试：扩展 = 返回一张新表。

(provide (struct-out op-registry)
         make-op-registry op-register op-lookup op-run)

(struct op-registry (handlers) #:transparent)   ; hash : tag -> handler

;; entries : (listof (cons tag handler))
(define (make-op-registry entries)
  (op-registry (for/hash ([e (in-list entries)]) (values (car e) (cdr e)))))

;; 加 / 覆盖一条原语（返回新表）。
(define (op-register reg tag handler)
  (op-registry (hash-set (op-registry-handlers reg) tag handler)))

(define (op-lookup reg tag)
  (hash-ref (op-registry-handlers reg) tag #f))

(define (op-run reg ctx st ev o)
  (define h (op-lookup reg (car o)))
  (if h (h ctx st ev (cdr o)) (values st '())))

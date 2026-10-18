#lang racket

;;; env/scope.rkt —— 作用域谓词（纯值）
;;; layer  : env
;;; effect : 无（纯值）

;;; scope 名是开放 symbol，存在 environment 的 scopes 表；结构不带名字。
;;; dispatch 按 scope 过滤候选规则：
;;;
;;;     scope-ok? scopes state scope-id  -> bool
;;;
;;; 约定：
;;;   'always 永远成立（内置）；
;;;   未注册 scope -> #f（保守；配置拼错会表现为“规则不生效”，而不是悄悄成立）。
;;;
;;; test : state -> bool。需要事件 / 主体时，后续可扩展成 ctx -> bool；
;;; 目前只依赖 State，保证 scope 可单测、可重放。

(provide (struct-out scope)
         make-scope
         scope-ok?
         scope-known?)

(require "../model/state.rkt")

(struct scope (test) #:transparent)
;; test : (state -> boolean)

(define (make-scope test)
  (unless (procedure? test)
    (error 'make-scope "scope test 要是过程：~a" test))
  (scope test))

(define (scope-known? scopes id)
  (or (eq? id 'always) (hash-has-key? scopes id)))

(define (scope-ok? scopes state id)
  (cond
    [(eq? id 'always) #t]
    [else
     (define s (hash-ref scopes id #f))
     (and s ((scope-test s) state))]))

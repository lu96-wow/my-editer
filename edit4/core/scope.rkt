#lang racket

;;; edit4/core/scope.rkt —— 作用域注册表（数据）
;;;
;;; scope 是 World 的函数，注册成数据（edit3 把 scope 写死在 step 的 cond 里）。
;;; 内置 always / (prefix NAME)；其余查注册表。未知 scope 视为成立（插件可后补定义）。

(provide (struct-out scope-registry)
         make-scope-registry scope-register scope-lookup scope-registry-merge
         scope-ok?)

(require "world.rkt" racket/list)

(struct scope-registry (table) #:transparent)       ; name -> (World -> Bool)

(define (make-scope-registry [entries '()])
  (scope-registry (for/hash ([e (in-list entries)]) (values (car e) (cdr e)))))

(define (scope-register reg name pred)
  (scope-registry (hash-set (scope-registry-table reg) name pred)))

(define (scope-lookup reg name)
  (hash-ref (scope-registry-table reg) name #f))

;; 叠加：b 覆盖 a 的同名 scope。
(define (scope-registry-merge a b)
  (scope-registry
   (for/fold ([t (scope-registry-table a)]) ([(k v) (in-hash (scope-registry-table b))])
     (hash-set t k v))))

(define (scope-ok? scopes world scope)
  (cond
    [(eq? scope 'always) #t]
    [(and (pair? scope) (eq? 'prefix (car scope)))
     (eq? (world-prefix world) (cadr scope))]
    [else (define p (scope-lookup scopes scope)) (if p (p world) #t)]))

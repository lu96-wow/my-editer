#lang racket

;;; lab-rebuild/kernel/runtime.rkt —— 运行时（注册表 + 服务）与上下文。

(require "registry.rkt" "session.rkt")

(provide (struct-out runtime) make-runtime
         service-ref service-put
         (struct-out ctx) ctx-with-session)

(struct runtime (registry services) #:transparent)
;; services : hash 名 -> 值（root / runner / 特性状态）

(define (make-runtime registry [services (hash)])
  (runtime registry services))

(define (service-ref ctx name) (hash-ref (runtime-services (ctx-runtime ctx)) name #f))
(define (service-put c name val)
  (define rt (ctx-runtime c))
  (ctx (ctx-session c) (struct-copy runtime rt [services (hash-set (runtime-services rt) name val)])))

(struct ctx (session runtime) #:transparent)

(define (ctx-with-session c s) (ctx s (ctx-runtime c)))

#lang racket

;;; lab-rebuild/kernel/runtime.rkt —— 运行时（注册表 + 服务 + 主题 + 配置）与上下文。

(require "session.rkt" "registry.rkt")

(provide (struct-out runtime) make-runtime
         (struct-out ctx) ctx-with-session
         service-ref service-put service-add-source)

(struct runtime (registry services theme config sources) #:transparent)
;; services : hash 服务名 -> 服务值（runner 等，惰性获取）
;; theme    : face -> (list fg bg) 等
;; config   : hash 杂项
;; sources  : (listof (-> evt? / #f))  异步结果源（后端 on-source 注册）

(define (make-runtime registry [services (hash)] [theme (hash)] [config (hash)])
  (runtime registry services theme config '()))
(struct ctx (session runtime) #:transparent)

(define (ctx-with-session c s) (ctx s (ctx-runtime c)))

;; 服务：特性在 init 时把状态/runner 放进 runtime.services（per-runtime，可测）。
(define (service-ref ctx name) (hash-ref (runtime-services (ctx-runtime ctx)) name #f))
(define (service-put c name val)
  (define rt (ctx-runtime c))
  (ctx (ctx-session c) (struct-copy runtime rt [services (hash-set (runtime-services rt) name val)])))

;; 异步结果源：后端登记到事件循环，结果到达即唤醒。
(define (service-add-source c proc)
  (define rt (ctx-runtime c))
  (ctx (ctx-session c) (struct-copy runtime rt [sources (append (runtime-sources rt) (list proc))])))

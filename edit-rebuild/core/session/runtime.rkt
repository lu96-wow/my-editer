#lang racket

;;; edit-rebuild/core/session/runtime.rkt —— 可变运行时（纯外壳）
;;;
;;; 局部问题：会话里**需要原地可变**的那部分 —— 每-editor 命名服务、异步结果闸门登记。
;;; 值式字段放各子值；这里集中放 box / hash 这类可变容器，让可变性只有一个出口。

(provide (struct-out runtime)
         runtime-new
         runtime-service-ref runtime-service-put
         runtime-await-put runtime-await-ref runtime-await-remove)

(struct runtime (services awaiting) #:transparent)
;; services : (hash name -> any/c)    每-editor 命名状态（插件间共享 / 懒建服务）
;; awaiting : (hash id -> entry)      异步结果闸门登记

(define (runtime-new) (runtime (hash) (hash)))

(define (runtime-service-ref r name) (hash-ref (runtime-services r) name #f))

(define (runtime-service-put r name v)
  (struct-copy runtime r [services (hash-set (runtime-services r) name v)]))

(define (runtime-await-put r id entry)
  (struct-copy runtime r [awaiting (hash-set (runtime-awaiting r) id entry)]))

(define (runtime-await-ref r id) (hash-ref (runtime-awaiting r) id #f))

(define (runtime-await-remove r id)
  (struct-copy runtime r [awaiting (hash-remove (runtime-awaiting r) id)]))

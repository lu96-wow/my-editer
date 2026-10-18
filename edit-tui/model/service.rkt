#lang racket

;;; layer  : model
;;; effect : 无（纯数据 + 纯更新）
;;;
;;; model/service.rkt —— 插件异步查询的通用状态
;;;
;;; completion / docs 都需要同一套东西：
;;;   cache   : key -> 结果（成功结果才缓存）
;;;   pending : key -> #t（同一 key 只允许一个在途）
;;;   jobs    : job-id -> tag（回来时对账；tag 由调用方定义）
;;;
;;; 这里只做纯数据。提交 job、解释 submit-service-effect、worker 进程都在
;;; runtime / plugins/worker.rkt；本模块不知道 effect / engine。
;;;
;;; 约定：
;;;   · cache 的“有没有”用 service-cache-has? 判断（结果本身可以是 #f）；
;;;   · job-take 返回 (values tag service')，tag = #f 表示未知 / 过期 job；
;;;   · pending 的 key 与 cache 的 key 由调用方决定，通常相同。

(provide (struct-out service-state)
         service-empty
         service-request
         service-cache-ref
         service-cache-has?
         service-cache-set
         service-cache-remove
         service-pending?
         service-pending-add
         service-pending-del
         service-job-add
         service-job-take
         service-job-tag)

(require "state.rkt"
         "../base/id.rkt"
         "../base/effect.rkt"
         "../base/transition.rkt")

(struct service-state (cache pending jobs) #:transparent)
;; cache   : (hash/c any/c any/c)
;; pending : (hash/c any/c #t)
;; jobs    : (hash/c job-id any/c)   ; job-id -> tag

(define (service-empty) (service-state (hash) (hash) (hash)))

;;; ---------- cache ----------

(define (service-cache-ref s key [default #f])
  (hash-ref (service-state-cache s) key default))

(define (service-cache-has? s key)
  (hash-has-key? (service-state-cache s) key))

(define (service-cache-set s key value)
  (struct-copy service-state s
               [cache (hash-set (service-state-cache s) key value)]))

(define (service-cache-remove s key)
  (struct-copy service-state s
               [cache (hash-remove (service-state-cache s) key)]))

;;; ---------- pending ----------

(define (service-pending? s key)
  (hash-has-key? (service-state-pending s) key))

(define (service-pending-add s key)
  (struct-copy service-state s
               [pending (hash-set (service-state-pending s) key #t)]))

(define (service-pending-del s key)
  (struct-copy service-state s
               [pending (hash-remove (service-state-pending s) key)]))

;;; ---------- jobs ----------

(define (service-job-add s jid tag)
  (struct-copy service-state s
               [jobs (hash-set (service-state-jobs s) jid tag)]))

(define (service-job-tag s jid)
  (hash-ref (service-state-jobs s) jid #f))

(define (service-job-take s jid)
  (define js (service-state-jobs s))
  (values (hash-ref js jid #f)
          (struct-copy service-state s [jobs (hash-remove js jid)])))

;;; ---------- 一次请求 ----------

;; 分配 job-id、记 pending + job，并返回 (values state' service' query-effect)。
;; 调用方把 service' 放回自己的 store 槽，再把 effect 放进 transition。
(define (service-request state service kind payload tag)
  (define-values (jid s1) (state-next-id state 'job))
  (define service* (service-pending-add (service-job-add service jid tag) tag))
  (values s1 service* (query-effect jid kind payload)))

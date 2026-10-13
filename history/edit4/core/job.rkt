#lang racket

;;; edit4/core/job.rkt —— 异步工作（jobs / services），对齐 edit3
;;;
;;; 命令不阻塞：只把「想发的工作」登记进 World 的 job 账本（job-submit）；
;;; runtime 每帧取待办、去重后丢给 worker 线程池，结果以 job-event 回注事件流；
;;; runtime 收到后 job-finish + emit 'job，插件在钩子里消费。
;;;
;;;   job     : 一次工作请求（id + kind + payload + tag）
;;;   service : kind -> (payload -> result)；handler 在 worker 线程里跑，**只该是纯函数**
;;;             （不碰 World；要改就回注 job-event）。
;;;
;;; World.jobs 是不透明账本字段（默认 #f = 空），本模块解释它。

(provide (struct-out job) (struct-out service) (struct-out service-registry)
         make-service-registry service-register service-lookup service-names
         service-registry-merge
         job-submit jobs job-find job-finish job-done job-forget job-pending run-service)

(require "world.rkt" racket/list)

;;; ---------- 值类型 ----------

(struct job (id kind payload tag) #:transparent)
;; id      : 整数，唯一
;; kind    : symbol，选 service
;; payload : 任意数据（worker 的输入）
;; tag     : 任意数据（调用方标记；结果回来时原样带回，便于钩子分派）

(struct service (name handler) #:transparent)          ; handler : payload -> result
(struct service-registry (table) #:transparent)        ; table : hash name -> service

(define (make-service-registry [services '()])
  (service-registry (for/hash ([s (in-list services)]) (values (service-name s) s))))

(define (service-register reg s)
  (service-registry (hash-set (service-registry-table reg) (service-name s) s)))

(define (service-lookup reg name) (hash-ref (service-registry-table reg) name #f))
(define (service-names reg) (hash-keys (service-registry-table reg)))

;; 叠加：b 覆盖 a 的同名 service。
(define (service-registry-merge a b)
  (service-registry
   (for/fold ([t (service-registry-table a)]) ([(k v) (in-hash (service-registry-table b))])
     (hash-set t k v))))

;; 在 worker 里跑一个 job：查 service、调用 handler。未知 kind 直接报错。
(define (run-service reg j)
  (define s (service-lookup reg (job-kind j)))
  (if s
      ((service-handler s) (job-payload j))
      (error 'run-service "未知 service: ~a（可用: ~a）" (job-kind j) (service-names reg))))

;;; ---------- World 里的账本 ----------

(struct ledger (seq open done) #:transparent)

(define (the-ledger w) (or (world-jobs w) (ledger 0 (hash) (hash))))
(define (set-ledger w l) (world-set-jobs w l))

(define (open-table w) (ledger-open (the-ledger w)))
(define (done-table w) (ledger-done (the-ledger w)))

;; 待办（按 id 升序，保证确定顺序）。
(define (jobs w) (sort (hash-values (open-table w)) < #:key job-id))
(define (job-pending w) (jobs w))

;; 登记一个工作请求，返回新 World（id 自增）。
(define (job-submit w kind payload [tag #f])
  (define l (the-ledger w))
  (define id (ledger-seq l))
  (define j (job id kind payload tag))
  (values (set-ledger w (ledger (add1 id)
                                (hash-set (ledger-open l) id j)
                                (ledger-done l)))
          j))

(define (job-find w id) (hash-ref (open-table w) id #f))

;; 结果回注：open → done。不认识的 id 忽略。
(define (job-finish w id result)
  (define open (open-table w))
  (cond
    [(not (hash-has-key? open id)) w]
    [else (define l (the-ledger w))
          (set-ledger w (ledger (ledger-seq l)
                                (hash-remove open id)
                                (hash-set (done-table w) id result)))]))

(define (job-done w id) (hash-ref (done-table w) id #f))
(define (job-forget w id)
  (define l (the-ledger w))
  (set-ledger w (ledger (ledger-seq l) (ledger-open l) (hash-remove (done-table w) id))))

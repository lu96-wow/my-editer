#lang racket

;;; edit3/job.rkt —— 异步工作（jobs / services）
;;;
;;; 后台计算不塞进 step：step 是纯的，只把「想发的工作」登记进 State（`job-submit`）；
;;; runtime 每帧用 `jobs` 取待办、丢给 worker 线程池跑，结果以 `job-event` 回注事件流，
;;; step 收到后 `job-finish` 并 `emit 'job`，插件在钩子里消费结果。
;;;
;;;   job      : 一次工作请求（id + kind + payload + tag）
;;;   service  : kind → (payload -> result)；handler 在 worker 线程里跑，**只该是纯函数**
;;;              （不要碰 State；要改 State 就回注 job-event，让 step 去做）。
;;;
;;; State 里的账本（feature）：
;;;   'job-seq  : 下一个 id（整数）
;;;   'job-open : id -> job      （在途）
;;;   'job-done : id -> result   （已完成，供取用）
;;;
;;; 只依赖 state.rkt，不依赖 step，插件经 extension 即可用。

(provide (struct-out job)
         (struct-out service)
         (struct-out service-registry)
         make-service-registry service-register service-lookup service-names
         job-submit job-find job-finish job-done job-forget job-pending jobs
         run-service)

(require "state.rkt")

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

;; 在 worker 里跑一个 job：查 service、调用 handler。未知 kind 直接报错。
(define (run-service reg j)
  (define s (service-lookup reg (job-kind j)))
  (if s
      ((service-handler s) (job-payload j))
      (error 'run-service "未知 service: ~a（可用: ~a）" (job-kind j) (service-names reg))))

;;; ---------- 账本（纯） ----------

(define (job-open-table st) (feature-ref st 'job-open (hash)))
(define (job-done-table st) (feature-ref st 'job-done (hash)))

;; 登记一个工作请求，返回新 State 与 job（id 自增）。调用方可以丢掉 job —— runtime 的
;; `jobs` 会从 State 里取到它；保留 job 便于测试 / 立即引用。
(define (job-submit st kind payload [tag #f])
  (define id (feature-ref st 'job-seq 0))
  (define j (job id kind payload tag))
  (values (feature-set (feature-set st 'job-seq (add1 id))
                       'job-open (hash-set (job-open-table st) id j))
          j))

(define (job-find st id) (hash-ref (job-open-table st) id #f))

;; 待办（按 id 升序，保证确定顺序）。
(define (job-pending st)
  (sort (hash-values (job-open-table st)) < #:key job-id))

;; 默认的 jobs：所有在途请求。runtime 用已派发集合去重，所以每帧重算也安全。
(define (jobs st) (job-pending st))

;; 结果回注：open → done。
(define (job-finish st id result)
  (define open (job-open-table st))
  (cond
    [(not (hash-has-key? open id)) st]                ; 不认识的 id：忽略
    [else (feature-set (feature-set st 'job-open (hash-remove open id))
                       'job-done (hash-set (job-done-table st) id result))]))

(define (job-done st id) (hash-ref (job-done-table st) id #f))
(define (job-forget st id) (feature-set st 'job-done (hash-remove (job-done-table st) id)))

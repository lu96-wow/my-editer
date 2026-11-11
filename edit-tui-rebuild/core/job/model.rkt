#lang racket

;;; edit-tui/core/job/model.rkt —— 异步 job / service 的纯值模型
;;;
;;;   job      : 一次工作请求（id / kind / payload / tag）
;;;   service  : kind -> (payload -> result)
;;;   ledger   : 纯账本（next-id / open / done）
;;;
;;; worker / channel / thread 不在这里；boot/jobs 解释 ledger。
;;; tag 是调用方的请求身份：结果回来时原样带回，用于版本 / selection 校验。

(provide (struct-out job)
         (struct-out job-error)
         (struct-out service)
         (struct-out service-registry)
         (struct-out job-ledger)
         empty-job-ledger
         job-submit
         job-find
         job-pending
         job-finish
         job-done
         job-forget
         make-service-registry
         service-register
         service-lookup
         service-names
         service-registry-merge
         run-service)

(require racket/list)

(struct job (id kind payload tag) #:transparent)
(struct job-error (message) #:transparent)

(struct service (name handler) #:transparent)
(struct service-registry (table) #:transparent)

(struct job-ledger
  (next-id open done)
  #:transparent)

(define empty-job-ledger (job-ledger 0 (hash) (hash)))

(define (job-submit ledger kind payload [tag #f])
  (define id (job-ledger-next-id ledger))
  (define j (job id kind payload tag))
  (values (job-ledger (add1 id)
                      (hash-set (job-ledger-open ledger) id j)
                      (job-ledger-done ledger))
          j))

(define (job-find ledger id)
  (hash-ref (job-ledger-open ledger) id #f))

;; 按 id 升序，保证派发顺序确定。
(define (job-pending ledger)
  (sort (hash-values (job-ledger-open ledger)) < #:key job-id))

(define (job-finish ledger id result)
  (define open (job-ledger-open ledger))
  (cond
    [(not (hash-has-key? open id)) ledger]
    [else
     (job-ledger (job-ledger-next-id ledger)
                 (hash-remove open id)
                 (hash-set (job-ledger-done ledger) id result))]))

(define (job-done ledger id)
  (hash-ref (job-ledger-done ledger) id #f))

(define (job-forget ledger id)
  (job-ledger (job-ledger-next-id ledger)
              (job-ledger-open ledger)
              (hash-remove (job-ledger-done ledger) id)))

;;; ════════════════ services ════════════════

(define (make-service-registry [services '()])
  (service-registry
   (for/hash ([s (in-list services)]) (values (service-name s) s))))

(define (service-register reg s)
  (service-registry (hash-set (service-registry-table reg) (service-name s) s)))

(define (service-lookup reg name)
  (hash-ref (service-registry-table reg) name #f))

(define (service-names reg)
  (hash-keys (service-registry-table reg)))

;; b 覆盖 a 的同名 service。
(define (service-registry-merge a b)
  (service-registry
   (for/fold ([t (service-registry-table a)])
             ([(k v) (in-hash (service-registry-table b))])
     (hash-set t k v))))

;; worker 线程只调用这里；handler 必须是纯的。
(define (run-service reg j)
  (define s (service-lookup reg (job-kind j)))
  (if s
      ((service-handler s) (job-payload j))
      (error 'run-service "未知 service: ~a（可用: ~a）"
             (job-kind j) (service-names reg))))

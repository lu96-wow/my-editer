#lang racket

;;; edit-tui/host/jobs.rkt —— worker runtime
;;;
;;; 纯账本在 editor-state.jobs；这里负责：
;;;   · worker 线程
;;;   · dispatch 未派发的 open job
;;;   · worker 结果作为 job-result-event 放回 host 事件 channel

(require racket/async-channel
         "../core/job/api.rkt"
         "../editor/job.rkt"
         "event.rkt")

(provide (struct-out job-runtime)
         start-job-runtime
         stop-job-runtime
         dispatch-jobs!
         forget-dispatched-job!
         job-runtime-event-channel)

(struct job-runtime
  (request-channel
   event-channel
   dispatched     ; mutable hash job-id -> #t
   services       ; service-registry
   workers)
  #:mutable
  #:transparent)

(define (start-job-runtime services
                           #:event-channel [event-channel (make-async-channel)]
                           #:workers [workers 2])
  (define registry (if (service-registry? services)
                       services
                       (make-service-registry services)))
  (define request-channel (make-async-channel))
  (define threads
    (for/list ([_ (in-range (max 1 workers))])
      (thread
       (λ ()
         (let loop ()
           (define j (async-channel-get request-channel))
           (define result
             (with-handlers ([exn:fail? (λ (e) (job-error (exn-message e)))])
               (run-service registry j)))
           (async-channel-put event-channel
                              (job-result-event (job-id j) (job-kind j)
                                                result (job-tag j)))
           (loop))))))
  (job-runtime request-channel event-channel (make-hash) registry threads))

(define (stop-job-runtime runtime)
  (for ([t (in-list (job-runtime-workers runtime))])
    (kill-thread t))
  (void))

(define (dispatch-jobs! runtime ledger)
  (for ([j (in-list (job-pending ledger))])
    (unless (hash-has-key? (job-runtime-dispatched runtime) (job-id j))
      (hash-set! (job-runtime-dispatched runtime) (job-id j) #t)
      (async-channel-put (job-runtime-request-channel runtime) j)))
  (void))

(define (forget-dispatched-job! runtime id)
  (hash-remove! (job-runtime-dispatched runtime) id)
  (void))

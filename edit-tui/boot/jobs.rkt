#lang racket

;;; edit-tui/boot/jobs.rkt —— worker runtime：把 job ledger 变成真实后台工作
;;;
;;; 纯账本在 app-state.jobs；本模块负责：
;;;   · 启动 worker 线程；
;;;   · 把尚未派发的 open job 丢进请求 channel；
;;;   · worker 跑纯 service，把 job-result-event 放回事件 channel；
;;;   · 结果由 run-loop 写回 ledger。
;;;
;;; 这里不解释结果，也不碰 state；只做派发和回注。

(provide (struct-out job-runtime)
         start-job-runtime
         stop-job-runtime
         dispatch-jobs!
         forget-dispatched-job!
         job-runtime-event-channel
         job-runtime-post-event!
         job-runtime-read-event)

(require racket/async-channel
         "../core/skeleton.rkt"
         "../app/event.rkt")

(struct job-runtime
  (request-channel
   event-channel
   dispatched        ; mutable hash: job-id -> #t
   services          ; service-registry
   workers)          ; (listof thread)
  #:mutable
  #:transparent)

(define (start-job-runtime services
                           #:event-channel [event-channel (make-async-channel)]
                           #:workers [workers 2])
  (define registry (if (service-registry? services)
                       services
                       (make-service-registry services)))
  (define request-channel (make-channel))
  (define threads
    (for/list ([_ (in-range (max 1 workers))])
      (thread
       (lambda ()
         (let loop ()
           (define j (channel-get request-channel))
           (define result
             (with-handlers ([exn:fail? (lambda (e) (job-error (exn-message e)))])
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

(define (job-runtime-post-event! runtime ev)
  (async-channel-put (job-runtime-event-channel runtime) ev))

(define (job-runtime-read-event runtime)
  (async-channel-get (job-runtime-event-channel runtime)))

;; 派发尚未发过的 open jobs。结果回来前不重复派发。
(define (dispatch-jobs! runtime ledger)
  (for ([j (in-list (job-pending ledger))])
    (unless (hash-has-key? (job-runtime-dispatched runtime) (job-id j))
      (hash-set! (job-runtime-dispatched runtime) (job-id j) #t)
      (channel-put (job-runtime-request-channel runtime) j)))
  (void))

;; run-loop 收到结果后清掉 dispatched 记录，避免长会话里账本无限增长。
(define (forget-dispatched-job! runtime id)
  (hash-remove! (job-runtime-dispatched runtime) id)
  (void))

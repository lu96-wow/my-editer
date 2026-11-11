#lang racket

;;; edit-tui-rebuild/host/timers.rkt —— timer runtime（host 副作用层）

(require racket/async-channel
         "../editor/timer.rkt")

(provide (struct-out timer-runtime)
         start-timer-runtime
         stop-timer-runtime
         timer-runtime-service
         schedule-timer!
         cancel-timer!)

(struct timer-runtime
  (event-channel
   next-id
   active)
  #:mutable
  #:transparent)

(define (start-timer-runtime #:event-channel [event-channel (make-async-channel)])
  (timer-runtime event-channel 0 (make-hash)))

(define (schedule-timer! rt delay-ms)
  (define id (timer-runtime-next-id rt))
  (set-timer-runtime-next-id! rt (add1 id))
  (define t
    (thread
     (λ ()
       (sleep (/ (max 0 delay-ms) 1000.0))
       (hash-remove! (timer-runtime-active rt) id)
       (async-channel-put (timer-runtime-event-channel rt) (timer-event id)))))
  (hash-set! (timer-runtime-active rt) id t)
  id)

(define (cancel-timer! rt id)
  (define t (hash-ref (timer-runtime-active rt) id #f))
  (when t
    (kill-thread t)
    (hash-remove! (timer-runtime-active rt) id))
  (void))

(define (stop-timer-runtime rt)
  (for ([t (in-hash-values (timer-runtime-active rt))])
    (kill-thread t))
  (hash-clear! (timer-runtime-active rt))
  (void))

(define (timer-runtime-service rt)
  (timer-service (λ (delay) (schedule-timer! rt delay))
                 (λ (id) (cancel-timer! rt id))))

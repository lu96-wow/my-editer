#lang racket

;;; edit-tui/boot/timers.rkt —— 单线程 timer runtime
;;;
;;; 只做一件事：定时把 timer-event 放回统一的 async event channel。
;;; debounce 由调用方用 timer-id 判断：旧 timer 的事件直接忽略即可。
;;;
;;; 一个 scheduler 线程维护 deadlines；schedule/cancel 走 async channel，
;;; 不和 worker / terminal reader 抢同一把锁。

(provide (struct-out timer-runtime)
         start-timer-runtime
         stop-timer-runtime
         schedule-timer!
         cancel-timer!
         timer-runtime-event-channel)

(require racket/async-channel
         racket/match
         "../app/event.rkt")

(struct timer-runtime
  (schedule-channel
   event-channel
   deadlines       ; mutable hash: timer-id -> deadline-ms
   next-id
   worker)
  #:mutable
  #:transparent)

(define (start-timer-runtime
         #:event-channel [event-channel (make-async-channel)])
  (define schedule-channel (make-async-channel))
  (define deadlines (make-hash))
  (define next-id (box 0))
  (define rt (timer-runtime schedule-channel event-channel deadlines next-id #f))
  (define worker
    (thread
     (λ ()
       (let loop ()
         (define now (current-inexact-milliseconds))
         (define next-deadline
           (for/fold ([m #f]) ([(id d) (in-hash deadlines)])
             (if (or (not m) (< d m)) d m)))
         (define wait
           (and next-deadline (max 0 (/ (- next-deadline now) 1000.0))))
         (define ev (if wait (sync/timeout wait schedule-channel) (sync schedule-channel)))
         (cond
           [(not ev) ; timeout
            (define now* (current-inexact-milliseconds))
            (define due
              (for/list ([(id d) (in-hash deadlines)] #:when (<= d now*)) id))
            (for ([id (in-list due)])
              (hash-remove! deadlines id)
              (async-channel-put event-channel (timer-event id)))
            (loop)]
           [else
            (match ev
              [(list 'schedule id deadline) (hash-set! deadlines id deadline) (loop)]
              [(list 'cancel id) (hash-remove! deadlines id) (loop)]
              [_ (loop)])])))))
  (set-timer-runtime-worker! rt worker)
  rt)

(define (stop-timer-runtime rt)
  (kill-thread (timer-runtime-worker rt))
  (void))

(define (schedule-timer! rt delay-ms)
  (define id (unbox (timer-runtime-next-id rt)))
  (set-box! (timer-runtime-next-id rt) (add1 id))
  (async-channel-put (timer-runtime-schedule-channel rt)
                     (list 'schedule id
                           (+ (current-inexact-milliseconds) (max 0 delay-ms))))
  id)

(define (cancel-timer! rt id)
  (async-channel-put (timer-runtime-schedule-channel rt) (list 'cancel id))
  (void))

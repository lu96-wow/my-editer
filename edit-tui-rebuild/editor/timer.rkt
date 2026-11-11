#lang racket

;;; edit-tui-rebuild/editor/timer.rkt —— 轻量 timer runtime
;;;
;;; timer 事件和 job 结果共用 host 事件 channel。
;;; 插件通过 editor-schedule-timer! / cancel 使用，不直接碰线程。

(require racket/async-channel
         "context.rkt")

(provide (struct-out timer-event)
         (struct-out timer-runtime)
         start-timer-runtime
         stop-timer-runtime
         schedule-timer!
         cancel-timer!
         editor-set-timer-runtime!
         editor-schedule-timer!
         editor-cancel-timer!)

(struct timer-event (id) #:transparent)

(struct timer-runtime
  (event-channel
   next-id
   active)   ; hash id -> thread
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

;;; ════════════════ editor 便捷入口 ════════════════

(define (editor-set-timer-runtime! ed rt)
  (set-editor-timer-runtime! ed rt))

(define (editor-schedule-timer! ed delay-ms)
  (define rt (editor-timer-runtime ed))
  (and rt (schedule-timer! rt delay-ms)))

(define (editor-cancel-timer! ed id)
  (define rt (editor-timer-runtime ed))
  (when (and rt id) (cancel-timer! rt id)))

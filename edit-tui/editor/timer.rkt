#lang racket

;;; edit-tui/editor/timer.rkt —— timer 事件 / editor 侧调度接口
;;;
;;; 线程 / channel / kill 在 host/timers.rkt。
;;; editor 只保存一个 timer-service（schedule/cancel 闭包），插件通过
;;; editor-schedule-timer! / editor-cancel-timer! 使用。

(require "context.rkt")

(provide (struct-out timer-event)
         (struct-out timer-service)
         editor-set-timer-service!
         editor-schedule-timer!
         editor-cancel-timer!)

(struct timer-event (id) #:transparent)

(struct timer-service
  (schedule   ; (delay-ms -> timer-id)
   cancel)    ; (timer-id -> void)
  #:transparent)

(define (editor-set-timer-service! ed svc)
  (set-editor-timer-service! ed svc))

(define (editor-schedule-timer! ed delay-ms)
  (define svc (editor-timer-service ed))
  (and svc ((timer-service-schedule svc) delay-ms)))

(define (editor-cancel-timer! ed id)
  (define svc (editor-timer-service ed))
  (when (and svc id) ((timer-service-cancel svc) id)))

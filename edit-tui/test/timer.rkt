#lang racket

;;; timer runtime：schedule -> timer-event -> plugin handle-timer。

(require rackunit
         racket/async-channel
         "../editor/host-api.rkt"
         "../host/timers.rkt")

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))

(define (handle-timer ed state ps ev)
  (values (state-with-flash state "timer fired")
          (add1 ps)
          '()))

(define plugin
  (make-plugin #:id 'timer-test #:state 0 #:handle-timer handle-timer))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list plugin)))
(define state (make-app-state #:plugin-states (plugins->states (list plugin))))

(define ch (make-async-channel))
(define rt (start-timer-runtime #:event-channel ch))
(editor-set-timer-service! ed (timer-runtime-service rt))

(define id (editor-schedule-timer! ed 10))
(check-true (exact-nonnegative-integer? id))
(define ev (async-channel-get ch))
(check-true (timer-event? ev))
(check-equal? (timer-event-id ev) id)

(define-values (state* actions*) (run-plugin-timer-handlers ed state ev))
(check-equal? actions* '())
(check-equal? (state-plugin-state state* 'timer-test) 1)
(check-equal? (state-flash state*) "timer fired")

(stop-timer-runtime rt)
(displayln "edit-tui-rebuild/test/timer.rkt: ok")

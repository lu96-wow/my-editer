#lang racket

;;; 自动补全：change -> debounce timer -> 自动打开 completion。
;;; accept 后的一次 change 必须被 suppress，不能马上重新弹。

(require rackunit
         racket/async-channel
         "../main.rkt"
         "../demo/completion-docs.rkt")

(define engine demo-engine)
(define timer-events (make-async-channel))
(define timers (start-timer-runtime #:event-channel timer-events))

(define-values (s1 p1) (sync-ui/panels! demo-state engine))
(define-values (s2 p2) (prepare-demo! s1 engine #:timer-runtime timers))

;; 在 tw 后输入 i：产生 doc-change，prepare 消费并调度 debounce timer。
(define-values (s3 acts3) (step s2 (key-event (key 'i))))
(define s4 (run-actions s3 engine acts3))
(define-values (s5 p5) (prepare-demo! s4 engine #:timer-runtime timers))
(check-equal? (app-state-pending-doc-changes s5) '())

;; timer 到点，自动打开 completion。
(define tev (async-channel-get timer-events))
(check-true (timer-event? tev))
(define s6 (handle-auto-timer! s5 (timer-event-id tev)))
(check-not-false (hash-ref (app-state-store s6) 'demo/completion #f))
(define-values (s7 p7) (prepare-demo! s6 engine #:timer-runtime timers))
(check-true (string-contains? (engine-view-text engine 40) "twice"))

;; Enter 接受；随后产生的编辑 change 不应自动重开。
(define-values (s8 acts8) (step s7 (key-event (key 'enter))))
(define s9 (run-actions s8 engine acts8))
(define-values (s10 p10) (prepare-demo! s9 engine #:timer-runtime timers))
(check-false (hash-ref (app-state-store s10) 'demo/completion #f))

(stop-timer-runtime timers)
(displayln "edit-tui-rebuild/test/demo-completion-docs-auto.rkt: ok")

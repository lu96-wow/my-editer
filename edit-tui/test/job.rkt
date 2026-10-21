#lang racket

;;; 异步基础：纯 job 账本、app-state 迁移、worker runtime、run-loop 结果回注。

(require rackunit
         racket/async-channel
         "../main.rkt")

;;; ════════════════ 纯账本 ════════════════

(define-values (l1 j1) (job-submit empty-job-ledger 'echo "hi" 'tag1))
(check-equal? (map job-id (job-pending l1)) (list (job-id j1)))
(check-equal? (job-find l1 (job-id j1)) j1)
(check-equal? (job-done l1 (job-id j1)) #f)

(define l2 (job-finish l1 (job-id j1) "ok"))
(check-equal? (job-pending l2) '())
(check-equal? (job-done l2 (job-id j1)) "ok")
;; 重复 finish / 未知 id 是 no-op
(check-equal? (job-finish l2 (job-id j1) "again") l2)

(define l3 (job-forget l2 (job-id j1)))
(check-equal? (job-done l3 (job-id j1)) #f)

;; 未知 service 报错。
(check-exn exn:fail?
           (lambda ()
             (run-service (make-service-registry '()) j1)))

;;; ════════════════ app-state ════════════════

(define engine (make-engine))
(define table (keys [(key 'a) 'a]))
(define-values (store actions)
  (resource-open resource-store-empty
                 #:name "job-doc"
                 #:text "hello"
                 #:key-table table))
(define vid 1)
(define layout
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor
                              (make-panel 'editor 'editor
                                          #:views (list vid)
                                          #:active vid))
               #:focus 'editor))
(define state0
  (run-actions (make-app-state #:layout layout
                               #:resources store
                               #:area (rect 0 0 20 5))
               engine actions))
(define-values (state1 ajob)
  (app-state-submit-job state0 'echo 42 'tag-app))
(check-equal? (length (job-pending (app-state-jobs state1))) 1)
(define state2 (app-state-finish-job state1 (job-id ajob) 84))
(check-equal? (job-done (app-state-jobs state2) (job-id ajob)) 84)

;;; ════════════════ worker runtime ════════════════

(define runtime
  (start-job-runtime
   (list (service 'echo (lambda (payload) (* 2 payload))))
   #:workers 1))
(dispatch-jobs! runtime (app-state-jobs state1))
(define result-event (async-channel-get (job-runtime-event-channel runtime)))
(check-true (job-result-event? result-event))
(check-equal? (job-result-event-id result-event) (job-id ajob))
(check-equal? (job-result-event-kind result-event) 'echo)
(check-equal? (job-result-event-result result-event) 84)
(check-equal? (job-result-event-tag result-event) 'tag-app)
(stop-job-runtime runtime)

;;; ════════════════ run-loop 结果回注 ════════════════

(define events
  (box (list (job-result-event (job-id ajob) 'echo 99 'tag-app)
             (quit-event))))
(define (next-event)
  (define xs (unbox events))
  (set-box! events (cdr xs))
  (car xs))
(define final
  (run-loop state1 engine
            #:read-event next-event
            #:write-bytes (lambda (b) (void))))
(check-true (app-state-quit? final))
(check-equal? (job-done (app-state-jobs final) (job-id ajob)) 99)

(displayln "edit-tui-rebuild/test/job.rkt: ok")

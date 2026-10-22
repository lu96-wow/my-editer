#lang racket

;;; 连续输入时 completion 不每键 refine：先只 reschedule idle timer；
;;; 停键后的 timer event 才提交 completion/docs job。

(require rackunit
         racket/async-channel
         "../main.rkt"
         "../demo/completion-docs.rkt")

(define engine demo-engine)
(define job-rt (start-job-runtime demo-services #:workers 1))
(define job-ch (job-runtime-event-channel job-rt))
(define timer-ch (make-async-channel))
(define timers (start-timer-runtime #:event-channel timer-ch))

(define (drain-jobs state [guard 30])
  (cond
    [(zero? guard) (error 'drain-jobs "guard exhausted")]
    [else
     (dispatch-jobs! job-rt (app-state-jobs state))
     (cond
       [(null? (job-pending (app-state-jobs state))) state]
       [else
        (define ev (async-channel-get job-ch))
        (drain-jobs (handle-job-result state ev) (sub1 guard))])]))

(define-values (s1 _p1) (sync-ui/panels! demo-state engine))
(define-values (s2 _o2) (prepare-demo! s1 engine #:timer-runtime timers))

;; 手动开补全并清空初始 completion/docs job。
(define-values (s3 _a3) (step s2 (key-event (key 'o 'ctrl))))
(check-not-false (hash-ref (app-state-store s3) 'demo/completion #f))
(define s4 (drain-jobs s3))
(check-equal? (job-pending (app-state-jobs s4)) '())

;; 继续输入：只调度 timer，不立即起 job。
(define-values (s5 acts5) (step s4 (key-event (key 'i))))
(define s6 (run-actions s5 engine acts5))
(define-values (s7 _p7) (prepare-demo! s6 engine #:timer-runtime timers))
(check-equal? (job-pending (app-state-jobs s7)) '())
(check-not-false (hash-ref (app-state-store s7) 'demo/completion #f))

;; 停键 idle 后才 refine，产生新的 completion job。
(define tev (async-channel-get timer-ch))
(check-true (timer-event? tev))
(define s8 (handle-auto-timer! s7 (timer-event-id tev)))
(check-true (pair? (job-pending (app-state-jobs s8))))

(define s9 (drain-jobs s8))
(check-equal? (job-pending (app-state-jobs s9)) '())
(check-not-false (hash-ref (app-state-store s9) 'demo/completion #f))

(stop-job-runtime job-rt)
(stop-timer-runtime timers)
(displayln "edit-tui-rebuild/test/demo-completion-debounce.rkt: ok")

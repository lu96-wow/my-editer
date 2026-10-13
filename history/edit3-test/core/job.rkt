#lang racket

;;; edit3-test/job.rkt —— 异步工作（job 账本 / service / 经 step 的结果回注与钩子）

(require rackunit racket/list
         "../../edit3/core/state.rkt"
         "../../edit3/core/event.rkt"
         "../../edit3/core/job.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/plugins/async-demo.rkt")

(define SZ (cons 80 24))
(define (run1 st ev) (call-with-values (lambda () (step (refresh-panels! st) SZ ev)) (lambda (s e) s)))

;;; ---------- 1. 账本（纯） ----------

(define st0 (make-state))
(define-values (st1 j1) (job-submit st0 'echo (hash 'x 1) 'tag1))
(check-equal? (job-id j1) 0)
(check-equal? (job-kind j1) 'echo)
(check-equal? (job-tag j1) 'tag1)
(check-equal? (length (jobs st1)) 1)

(define-values (st2 j2) (job-submit st1 'echo (hash 'x 2) 'tag2))
(check-equal? (job-id j2) 1)
(check-equal? (jobs st2) (list j1 j2))              ; 按 id 升序
(check-equal? (job-find st2 0) j1)

(define st3 (job-finish st2 0 'done0))
(check-equal? (jobs st3) (list j2))                 ; 出队
(check-equal? (job-done st3 0) 'done0)
(check-false (job-find st3 0))
(check-equal? (job-finish st3 99 'x) st3)           ; 未知 id：幂等忽略

(define st4 (job-forget st3 0))
(check-false (job-done st4 0))

;;; ---------- 2. service 注册表 ----------

(define reg
  (make-service-registry
   (list (service 'echo (lambda (p) (hash-ref p 'x)))
         (service 'echo2 (lambda (p) (* 2 (hash-ref p 'x)))))))
(check-equal? (sort (service-names reg) symbol<?) '(echo echo2))
(check-equal? (run-service reg j1) 1)
(check-equal? (run-service reg (job 5 'echo2 (hash 'x 21) #f)) 42)
(check-exn exn:fail? (lambda () (run-service reg (job 6 'nope #f #f))))

(define reg2 (service-register (make-service-registry) (service 'z (lambda (_p) 'z))))
(check-equal? (run-service reg2 (job 0 'z #f #f)) 'z)

;;; ---------- 3. 经 step：登记 → 模拟 worker → 结果回注 → 'job 钩子 ----------

(define b0 (boot 80 24 #:plugins (list async-spec)))
(check-false (feature-ref b0 'async-loading #f))

;; M-o 触发登记
(define b1 (run1 b0 (key-event 'o '(alt))))
(check-true (and (feature-ref b1 'async-loading #f) #t))
(define pending (jobs b1))
(check-equal? (length pending) 1)
(define jb (car pending))
(check-equal? (job-kind jb) 'slow-words)
(check-equal? (job-tag jb) 'async-demo)

;; 模拟 worker：直接跑 service，再把结果以 job-event 回注 step
(define svc (feature-ref b1 'services (make-service-registry)))
(define result (run-service svc jb))
(check-equal? result '("async-item-0" "async-item-1" "async-item-2" "async-item-3"))

(define-values (b2 _effs) (step (refresh-panels! b1) SZ
                                (job-event (job-id jb) (job-kind jb) result (job-tag jb))))
(check-false (feature-ref b2 'async-loading #t))    ; loading 清掉
(check-equal? (feature-ref b2 'async-result '()) result)
(check-equal? (jobs b2) '())                        ; 已出队

;; 再次触发：id 不复用
(define b3 (run1 b2 (key-event 'o '(alt))))
(define jb2 (car (jobs b3)))
(check-not-equal? (job-id jb2) (job-id jb))

;; 不匹配 tag 的结果不写 async-result（钩子按 tag 分派）
(define-values (b4 _) (step (refresh-panels! b3) SZ
                            (job-event (job-id jb2) (job-kind jb2) 'zzz 'other)))
(check-equal? (feature-ref b4 'async-result '()) result)   ; 保持上一次
(check-true (and (job-done b4 (job-id jb2)) #t))           ; 但已入 done

(displayln "edit3/job.rkt: all tests passed")

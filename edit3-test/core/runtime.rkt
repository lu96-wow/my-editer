#lang racket

;;; edit3-test/runtime.rkt —— 事件循环 + worker 线程池（端到端：键盘触发 → worker 跑 →
;;;                            job-event 回注 → 钩子写 State → C-q 退出）

(require rackunit racket/list
         "../../edit3/core/state.rkt"
         "../../edit3/core/event.rkt"
         "../../edit3/core/job.rkt"
         "../../edit3/core/hook.rkt"
         "../../edit3/core/runtime.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/plugins/async-demo.rkt")

;; 装配（启用 async 插件），再加一个测试钩子：job 送达时置位。
(define base (boot 80 24 #:plugins (list async-spec)))
(define got (box #f))
(define st0 (feature-set base 'hooks
                         (cons (reaction* 'job (lambda (s _a) (set-box! got #t) s))
                               (feature-ref base 'hooks '()))))

;; 先直接触发一次 async-load，让 State 里有一个在途 job。
(define-values (st1 _e) (step st0 (cons 80 24) (key-event 'o '(alt))))
(check-true (and (feature-ref st1 'async-loading #f) #t))

;; 后端：结果没回来就一直发 tick；回来了就发 C-q（触发退出）。
(define (mk-backend)
  (backend
   (lambda () (cons 80 24))
   (lambda () (if (unbox got) (key-event 'q '(ctrl)) (tick-event 0)))
   (lambda (_pieces) (void))
   void))

(define st-final (run (mk-backend) st1))

(check-true (unbox got))                                       ; worker 结果确实回来了
(check-false (feature-ref st-final 'async-loading #t))         ; loading 清掉
(check-equal? (feature-ref st-final 'async-result '())
              '("async-item-0" "async-item-1" "async-item-2" "async-item-3"))
(check-equal? (jobs st-final) '())                             ; 在途清空

(displayln "edit3/runtime.rkt: all tests passed")

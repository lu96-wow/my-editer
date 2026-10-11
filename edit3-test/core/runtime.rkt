#lang racket

;;; edit3-test/runtime.rkt —— 事件循环 + worker 线程池（端到端：键盘触发 → worker 跑 →
;;;                            job-event 回注 → 钩子写 State → C-q 退出）

(require rackunit racket/list racket/file
         "../../edit3/core/state.rkt"
         "../../edit3/core/event.rkt"
         "../../edit3/core/job.rkt"
         "../../edit3/core/hook.rkt"
         "../../edit3/core/runtime.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/session.rkt"
         "../../edit3/core/window.rkt"
         "../../edit3/core/adapter.rkt"
         "../../edit3/plugins/async-demo.rkt"
         "../../edit3/plugins/completion.rkt")

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

;;; ---------- 场景 2：补全的模块导出走真实 worker 线程 ----------

(define tmp (make-temporary-file "ed3rt~a" 'directory))
(define rf (build-path tmp "a.rkt"))
(display-to-file "(require (rename-in racket/list [first zfirst]))\nz\n"
                 rf #:exists 'truncate)

(define cbase (boot 80 24 #:plugins (list completion-spec)))
(define-values (copened _) (open-file* cbase rf))
(set-point! (state-ed copened) (focused-vid copened) 1 1)   ; 光标在 "z" 后

;; 测试钩子：任何一个 job 回来就置位。
(define cgot (box #f))
(define c0 (feature-set copened 'hooks
                         (cons (reaction* 'job (lambda (s _a) (set-box! cgot #t) s))
                               (feature-ref copened 'hooks '()))))

;; 后端：第一次发 M-/（触发补全），之后 tick 直到 worker 回来，再 C-q。
(define sent? (box #f))
(define (mk-completion-backend)
  (backend
   (lambda () (cons 80 24))
   (lambda ()
     (cond
       [(not (unbox sent?)) (set-box! sent? #t) (key-event '/ '(alt))]
       [(unbox cgot) (key-event 'q '(ctrl))]
       [else (tick-event 0)]))
   (lambda (_pieces) (void))
   void))

(define cfinal (run (mk-completion-backend) c0))

(check-true (unbox cgot))                                      ; 真实 worker 结果回来了
(check-true (and (feature-ref cfinal 'completion #f) #t))      ; 菜单已开
(define ccands (hash-ref (feature-ref cfinal 'completion #f) 'candidates))
(check-true (and (member "zfirst" ccands) #t))                ; 来自 rename-in
(delete-directory/files tmp)

(displayln "edit3/runtime.rkt: all tests passed")

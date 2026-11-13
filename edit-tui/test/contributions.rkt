#lang racket

;;; 统一 contribution registry：
;;;   · job-result 只调用匹配 kind 的 handler
;;;   · 同名 job-service 直接报错

(require rackunit
         "../editor/host-api.rkt"
         "../editor/contributions.rkt")

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))

(define (make-job-plugin id kind)
  (make-plugin
   #:id id
   #:state 0
   #:services (list (service kind (λ (payload) payload)))
   #:handle-job
   (λ (ed state ps ev)
     (values state (add1 ps) '()))))

(define pa (make-job-plugin 'a 'job-a))
(define pb (make-job-plugin 'b 'job-b))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list pa pb)))
(define state (make-app-state #:plugin-states (plugins->states (list pa pb))))

(define ev (job-result-event 1 'job-a 'ok #f))
(define-values (s1 actions) (run-plugin-job-handlers ed state ev))
(check-equal? actions '())
(check-equal? (state-plugin-state s1 'a) 1)
(check-equal? (state-plugin-state s1 'b) 0)

;; 同名 service 冲突
(define p1 (make-plugin #:id 'x #:state #f
                        #:services (list (service 'dup (λ (x) x)))))
(define p2 (make-plugin #:id 'y #:state #f
                        #:services (list (service 'dup (λ (x) x)))))
(check-exn exn:fail?
           (λ () (make-editor #:engine (make-engine)
                              #:registry (make-hook-registry '())
                              #:plugins (list p1 p2))))

(displayln "edit-tui/test/contributions.rkt: ok")

;;; contribution 顺序：priority 小者先；同 priority 按注册顺序。
(define ordered
  (add-contribution
   (add-contribution
    (add-contribution empty-contribution-registry
                      point/frame-sync #f 'late #:priority 10 #:fn void)
    point/frame-sync #f 'early-a #:priority 5 #:fn void)
   point/frame-sync #f 'early-b #:priority 5 #:fn void))
(check-equal? (map contribution-owner
                  (registry-contributions ordered point/frame-sync))
              '(early-a early-b late))

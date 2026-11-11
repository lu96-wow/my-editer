#lang racket

;;; 插件状态所有权：
;;;   · sync / timer / job 回调只拿自己的 ps，返回自己的 ps'
;;;   · runtime 按 contribution owner 写回，不碰别的 owner
;;;   · 命令返回值里的 ps' 也只写回命令的 owner

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../host/final.rkt")

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))

(define bump-sync
  (λ (ed state ps) (values state (add1 ps))))
(define bump-timer
  (λ (ed state ps ev) (values state (add1 ps) '())))
(define bump-job
  (λ (ed state ps ev) (values state (add1 ps) '())))

(define pa
  (make-plugin #:id 'owner-a
               #:state 0
               #:sync bump-sync
               #:services (list (service 'job-a (λ (x) x)))
               #:handle-job bump-job
               #:handle-timer bump-timer))
(define pb
  (make-plugin #:id 'owner-b
               #:state 100
               #:sync bump-sync
               #:services (list (service 'job-b (λ (x) x)))
               #:handle-job bump-job
               #:handle-timer bump-timer))

(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list pa pb)))
(define state (make-app-state #:plugin-states (plugins->states (list pa pb))))

(define s1 (run-plugin-syncs ed state))
(check-equal? (editor-state-plugin-state s1 'owner-a) 1)
(check-equal? (editor-state-plugin-state s1 'owner-b) 101)

(define-values (s2 actions2)
  (run-plugin-timer-handlers ed s1 (timer-event 0)))
(check-equal? actions2 '())
(check-equal? (editor-state-plugin-state s2 'owner-a) 2)
(check-equal? (editor-state-plugin-state s2 'owner-b) 102)

(define-values (s3 actions3)
  (run-plugin-job-handlers ed s2 (job-result-event 0 'job-a 'ok #f)))
(check-equal? actions3 '())
(check-equal? (editor-state-plugin-state s3 'owner-a) 3)
(check-equal? (editor-state-plugin-state s3 'owner-b) 102)

;; 命令：owner-a 的 C-t 只改 owner-a。
(define command-plugin
  (make-plugin
   #:id 'owner-command
   #:state 0
   #:commands (keys [(key 't 'ctrl)
                     (λ (ed state ps) (values state (add1 ps) '()))])))

(define engine2 (make-engine))
(void (engine-create-buffer! engine2 1 "test" ""))
(void (engine-create-view! engine2 1 1))
(define ed2 (make-editor #:engine engine2
                         #:registry (make-hook-registry '())
                         #:plugins (list command-plugin)))
(define state2
  (make-app-state #:plugin-states (plugins->states (list command-plugin))))
(define s4 (handle-editor-event ed2 state2 (key-event (key 't 'ctrl))))
(check-equal? (editor-state-plugin-state s4 'owner-command) 1)

(displayln "edit-tui-rebuild/test/ownership.rkt: ok")

#lang racket

;;; 插件回调错误隔离：sync / hook / timer / command 抛异常不能打断整帧或整次操作。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../editor/error.rkt"
         "../core/command/api.rkt"
         "../host/input/dispatch.rkt")

(define (make-engine-with-user-doc)
  (define e (make-engine))
  (void (engine-create-buffer! e 1 "test" ""))
  (void (engine-create-view! e 1 1))
  e)

(define (state-for plugins)
  (make-app-state #:plugin-states (plugins->states plugins)
                  #:screen (rect 0 0 40 10)))

(define (editor-for engine plugins)
  (make-editor #:engine engine
               #:registry (make-hook-registry (plugins->hooks plugins))
               #:plugins plugins))

;;; ════════════════ sync ════════════════

(define bad-sync
  (make-plugin
   #:id 'bad-sync
   #:state 'ok
   #:sync (λ (ed state ps) (error 'sync-boom))))

(define engine1 (make-engine-with-user-doc))
(define ed1 (editor-for engine1 (list bad-sync)))
(define s1 (run-plugin-syncs ed1 (state-for (list bad-sync))))
(check-eq? (state-plugin-state s1 'bad-sync) 'ok)
(check-true (string-contains? (state-flash s1) "bad-sync"))
(check-true (string-contains? (state-flash s1) "sync"))
(check-equal? (length (state-errors s1)) 1)
(check-eq? (editor-error-source (car (state-errors s1))) 'plugin)
(check-eq? (editor-error-owner (car (state-errors s1))) 'bad-sync)

;;; ════════════════ overlay ════════════════

(define bad-overlay
  (make-plugin
   #:id 'bad-overlay
   #:state 'overlay-state
   #:overlays (λ (ed state ps) (error 'overlay-boom))))

(define engine5 (make-engine-with-user-doc))
(define ed5 (editor-for engine5 (list bad-overlay)))
(define-values (s5 overlays5)
  (run-plugin-overlays ed5 (state-for (list bad-overlay))))
(check-equal? overlays5 '())
(check-eq? (state-plugin-state s5 'bad-overlay) 'overlay-state)
(check-true (string-contains? (state-flash s5) "bad-overlay"))
(check-true (string-contains? (state-flash s5) "overlay"))
(check-equal? (length (state-errors s5)) 1)

;;; ════════════════ hook ════════════════

(define bad-hook
  (make-plugin
   #:id 'bad-hook
   #:state 'hook-state
   #:hooks
   (list
    (make-hook #:owner 'bad-hook
               #:id 'boom
               #:operation 'insert
               #:phase 'transform
               #:fn (λ (ctx ps) (error 'hook-boom))))))

(define engine2 (make-engine-with-user-doc))
(define ed2 (editor-for engine2 (list bad-hook)))
(define s2 (state-for (list bad-hook)))
(define-values (s2* actions2) (editor-insert! ed2 s2 1 "x"))
(check-equal? (engine-view-text engine2 1) "")
(check-eq? (state-plugin-state s2* 'bad-hook) 'hook-state)
(check-true (string-contains? (state-flash s2*) "bad-hook"))
(check-true (string-contains? (state-flash s2*) "hook"))
(check-equal? (length (state-errors s2*)) 1)
(check-eq? (editor-error-source (car (state-errors s2*))) 'hook)
(check-equal? actions2 '())

;;; ════════════════ timer ════════════════

(define bad-timer
  (make-plugin
   #:id 'bad-timer
   #:state 'timer-state
   #:handle-timer (λ (ed state ps ev) (error 'timer-boom))))

(define engine3 (make-engine-with-user-doc))
(define ed3 (editor-for engine3 (list bad-timer)))
(define-values (s3 actions3)
  (run-plugin-timer-handlers ed3 (state-for (list bad-timer)) (timer-event 0)))
(check-eq? (state-plugin-state s3 'bad-timer) 'timer-state)
(check-true (string-contains? (state-flash s3) "bad-timer"))
(check-equal? (length (state-errors s3)) 1)
(check-equal? actions3 '())

;;; ════════════════ command ════════════════

(define bad-command
  (make-plugin
   #:id 'bad-command
   #:state 'cmd-state
   #:commands (keys [(key 't 'ctrl)
                     (λ (ed state ps) (error 'command-boom))])))

(define engine4 (make-engine-with-user-doc))
(define ed4 (editor-for engine4 (list bad-command)))
(define s4 (state-for (list bad-command)))
(define-values (s4* actions4)
  (dispatch-key ed4 s4 (key 't 'ctrl)))
(check-eq? (state-plugin-state s4* 'bad-command) 'cmd-state)
(check-true (string-contains? (state-flash s4*) "bad-command"))
(check-true (string-contains? (state-flash s4*) "command"))
(check-equal? (length (state-errors s4*)) 1)
(check-eq? (editor-error-source (car (state-errors s4*))) 'command)
(check-equal? actions4 '())

(displayln "edit-tui/test/plugin-guard.rkt: ok")

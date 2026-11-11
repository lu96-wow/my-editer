#lang racket

;;; app-state = editor-core + editor-session。
;;; 改 core 不应碰 session，改 session 不应碰 core；core 不能承载 session。

(require rackunit
         "../editor/host-api.rkt"
         "../host/layout.rkt")

(define state (make-app-state))
(define core (editor-state-core state))
(define session (editor-state-session state))
(check-true (app-state? state))
(check-true (editor-core? core))
(check-true (editor-session? session))

;; session 更新保留 core 对象。
(define s-flash (editor-state-with-flash state "hi"))
(check-eq? (editor-state-core s-flash) core)
(check-equal? (editor-state-flash s-flash) "hi")

(define s-input (editor-state-with-input state 'input))
(check-eq? (editor-state-core s-input) core)
(check-eq? (editor-state-input s-input) 'input)

(define s-quit (editor-state-with-quit state #t))
(check-eq? (editor-state-core s-quit) core)
(check-true (editor-state-quit? s-quit))

;; core 更新保留 session 对象。
(define s-layout (editor-state-with-layout state 'layout))
(check-eq? (editor-state-session s-layout) session)
(check-eq? (editor-state-layout s-layout) 'layout)

(define s-resources (editor-state-with-resources state 'resources))
(check-eq? (editor-state-session s-resources) session)
(check-eq? (editor-state-resources s-resources) 'resources)

;; core 自己也能走 core 更新；session 写必须走 app-state。
(check-eq? (editor-state-layout (editor-state-with-layout core 'core-layout)) 'core-layout)
(check-exn exn:fail?
           (λ () (editor-state-with-flash core "x")))

;; 实际编辑操作传 app-state：core 更新后 session 对象保持不变。
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins '()))
(define app (make-app-state
             #:layout (make-editor-layout #:editor-view 1)
             #:area (rect 0 0 40 10)))
(define app-session (app-state-session app))
(define-values (app* _actions) (editor-insert! ed app 1 "x"))
(check-eq? (app-state-session app*) app-session)
(check-equal? (engine-view-text engine 1) "x")

(displayln "edit-tui-rebuild/test/state-split.rkt: ok")

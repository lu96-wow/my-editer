#lang racket

;;; app-state = editor-core + editor-session。
;;; 改 core 不应碰 session，改 session 不应碰 core；core 不能承载 session。

(require rackunit
         "../editor/host-api.rkt"
         "../host/layout.rkt")

(define state (make-app-state))
(define core (state-core state))
(define session (state-session state))
(check-true (app-state? state))
(check-true (editor-core? core))
(check-true (editor-session? session))

;; session 更新保留 core 对象。
(define s-flash (state-with-flash state "hi"))
(check-eq? (state-core s-flash) core)
(check-equal? (state-flash s-flash) "hi")

(define s-input (state-with-input state 'input))
(check-eq? (state-core s-input) core)
(check-eq? (state-input s-input) 'input)

(define s-quit (state-with-quit state #t))
(check-eq? (state-core s-quit) core)
(check-true (state-quit? s-quit))

;; core 更新保留 session 对象。
(define s-layout (state-with-layout state 'layout))
(check-eq? (state-session s-layout) session)
(check-eq? (state-layout s-layout) 'layout)

(define s-resources (state-with-resources state 'resources))
(check-eq? (state-session s-resources) session)
(check-eq? (state-resources s-resources) 'resources)

;; core 自己也能走 core 更新；session 写必须走 app-state。
(check-eq? (state-layout (state-with-layout core 'core-layout)) 'core-layout)
(check-exn exn:fail?
           (λ () (state-with-flash core "x")))

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

(displayln "edit-tui/test/state-split.rkt: ok")

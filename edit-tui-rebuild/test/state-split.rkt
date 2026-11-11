#lang racket

;;; editor-state = editor-core + editor-session。
;;; 改 core 不应碰 session，改 session 不应碰 core。

(require rackunit
         "../editor/host-api.rkt")

(define state (make-editor-state))
(define core (editor-state-core state))
(define session (editor-state-session state))

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

(displayln "edit-tui-rebuild/test/state-split.rkt: ok")

#lang racket

;;; 文档种类：user / ui / derived 的隔离与写能力。

(require rackunit
         racket/string
         "../editor/host-api.rkt")

(define e (make-engine))
(define (bytes s) (string->bytes/utf-8 s))

;; user
(void (engine-create-buffer! e 1 "user" "u"))
(void (engine-create-view! e 1 1))
;; ui
(void (engine-create-buffer! e 2 "*ui*" "" #:kind 'ui))
(void (engine-create-view! e 2 2))
;; derived intent
(void (engine-create-derived-buffer! e 10 "mirror" "d"
                                    #:owner 'test
                                    #:source-doc-id 1
                                    #:edit-policy 'intent))
(void (engine-create-view! e 10 10))
;; derived read-only
(void (engine-create-derived-buffer! e 11 "readonly" "r"
                                    #:owner 'test
                                    #:source-doc-id 1
                                    #:edit-policy 'read-only))
(void (engine-create-view! e 11 11))

(check-equal? (engine-doc-kind e 1) 'user)
(check-equal? (engine-doc-kind e 2) 'ui)
(check-equal? (engine-doc-kind e 10) 'derived)
(check-equal? (engine-view-kind e 10) 'derived)

(check-equal? (engine-derived-doc-owner e 10) 'test)
(check-equal? (engine-derived-doc-source e 10) 1)
(check-equal? (engine-derived-doc-edit-policy e 10) 'intent)

(check-true (and (memv 1 (engine-user-doc-ids e)) #t))
(check-true (and (memv 2 (engine-ui-doc-ids e)) #t))
(check-true (and (memv 10 (engine-derived-doc-ids e)) #t))
(check-false (memv 10 (engine-user-doc-ids e)))

;; UI 文本写被拒绝；derived intent 允许；read-only 拒绝。
(check-equal? (engine-apply-user-action! e (view-action 'insert 2 (bytes "x"))) '())
(check-equal? (engine-view-text e 2) "")
(check-true (pair? (engine-apply-user-action! e (view-action 'insert 10 (bytes "x")))))
(check-equal? (engine-view-text e 10) "xd")
(check-equal? (engine-apply-user-action! e (view-action 'insert 11 (bytes "x"))) '())
(check-equal? (engine-view-text e 11) "r")

;; derived 无 history：undo 是 no-op。
(check-equal? (engine-apply-user-action! e (view-action 'undo 10 #f)) '())
(check-equal? (engine-view-text e 10) "xd")

;; 内容投影写：user / ui / derived 各自只走自己的入口。
(check-false (engine-set-view-content! e 1 '("x") '(#f)))
(check-true (engine-set-view-content! e 2 '("ui") '(#f)))
(check-equal? (engine-view-text e 2) "ui")
(check-false (engine-set-derived-content! e 1 '("x") '(#f)))
(check-false (engine-set-derived-content! e 2 '("x") '(#f)))
(check-true (engine-set-derived-content! e 10 '("derived") '(#f)))
(check-equal? (engine-view-text e 10) "derived")

;; face / cursor 是通用 view 属性，user view 也可写。
(engine-set-view-cursor! e 1 0 #:column 1)
(check-equal? (engine-view-point-column e 1) 1)

(displayln "edit-tui/test/engine-kinds.rkt: ok")

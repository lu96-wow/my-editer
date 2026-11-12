#lang racket

;;; engine doc kind：用户文档和 UI 投影文档分开。
;;; 插件默认按 user doc 查询；UI doc 不进入语法着色等用户文档流程。

(require rackunit
         "../editor/host-api.rkt"
         "../edit.rkt")

(define-values (ed state) (make-editor-app #:initial-name "a.rkt"
                                            #:initial-text "#lang racket\n"))

(check-eq? (editor-doc-kind ed 1) 'user)
(check-eq? (editor-doc-kind ed 2) 'ui)
(check-eq? (editor-view-kind ed 1) 'user)
(check-eq? (editor-view-kind ed 2) 'ui)
(check-equal? (editor-user-doc-ids ed) '(1))
(check-not-false (memq 2 (editor-ui-doc-ids ed)))
(check-not-false (memq 7 (editor-ui-doc-ids ed)))
(check-false (memq 7 (editor-user-doc-ids ed)))
(check-equal? (editor-user-view-ids ed) '(1))
(check-not-false (memq 2 (editor-ui-view-ids ed)))
(check-not-false (memq 7 (editor-ui-view-ids ed)))
(check-false (memq 7 (editor-user-view-ids ed)))

;; 直接走 engine 的 API：默认 user；显式 ui；remove 时一起清掉 kind。
(define e (make-engine))
(void (engine-create-buffer! e 1 "user" ""))
(void (engine-create-buffer! e 2 "*ui*" "" #:kind 'ui))
(void (engine-create-view! e 1 1))
(void (engine-create-view! e 2 2))
(check-eq? (engine-doc-kind e 1) 'user)
(check-eq? (engine-doc-kind e 2) 'ui)
(check-eq? (engine-view-kind e 1) 'user)
(check-eq? (engine-view-kind e 2) 'ui)
(check-equal? (engine-user-doc-ids e) '(1))
(check-equal? (engine-ui-doc-ids e) '(2))
(check-equal? (engine-user-view-ids e) '(1))
(check-equal? (engine-ui-view-ids e) '(2))
;; split 出来的 view 跟随 source view 的 kind。
(void (engine-create-view-from-view! e 10 1))
(check-eq? (engine-view-kind e 10) 'user)
(check-not-false (memq 10 (engine-user-view-ids e)))
(check-false (memq 10 (engine-ui-view-ids e)))
(engine-remove-doc! e 2)
(check-equal? (engine-ui-doc-ids e) '())
(check-equal? (engine-ui-view-ids e) '())
(check-equal? (engine-user-doc-ids e) '(1))
(check-equal? (length (engine-user-view-ids e)) 2)
(check-not-false (memq 1 (engine-user-view-ids e)))
(check-not-false (memq 10 (engine-user-view-ids e)))

(displayln "edit-tui/test/doc-kind.rkt: ok")

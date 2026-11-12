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
(check-equal? (editor-user-doc-ids ed) '(1))
(check-not-false (memq 2 (editor-ui-doc-ids ed)))
(check-not-false (memq 7 (editor-ui-doc-ids ed)))
(check-false (memq 7 (editor-user-doc-ids ed)))

;; 直接走 engine 的 API：默认 user；显式 ui；remove 时一起清掉 kind。
(define e (make-engine))
(void (engine-create-buffer! e 1 "user" ""))
(void (engine-create-buffer! e 2 "*ui*" "" #:kind 'ui))
(check-eq? (engine-doc-kind e 1) 'user)
(check-eq? (engine-doc-kind e 2) 'ui)
(check-equal? (engine-user-doc-ids e) '(1))
(check-equal? (engine-ui-doc-ids e) '(2))
(engine-remove-doc! e 2)
(check-equal? (engine-ui-doc-ids e) '())
(check-equal? (engine-user-doc-ids e) '(1))

(displayln "edit-tui/test/doc-kind.rkt: ok")

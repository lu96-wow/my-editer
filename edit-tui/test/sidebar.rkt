#lang racket

;;; C-b：sidebar 显 / 隐。

(require rackunit
         "../editor/host-api.rkt"
         "../features/sidebar/api.rkt"
         "../core/layout/api.rkt"
         "../edit.rkt"
         "fixture.rkt")

(define-values (ed state) (make-test-editor))
(define s0 (state-with-area state (rect 0 0 60 15)))
(check-true (layout-panel-visible? (state-layout s0) 'filetree))

(define-values (s1 _a1) (editor-toggle-sidebar! ed s0))
(check-false (layout-panel-visible? (state-layout s1) 'filetree))
(check-equal? (editor-focus-panel-kind s1) 'editor)

(define-values (s2 _a2) (editor-toggle-sidebar! ed s1))
(check-true (layout-panel-visible? (state-layout s2) 'filetree))
(check-equal? (editor-focus-panel-kind s2) 'editor)

(displayln "edit-tui/test/sidebar.rkt: ok")

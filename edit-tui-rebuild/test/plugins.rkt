#lang racket

;;; pair / indent 两个正式插件。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../plugins/pair/plugin.rkt"
         "../plugins/indent/plugin.rkt")

(define (make-test-editor text line col)
  (define engine (make-engine))
  (void (engine-create-buffer! engine 1 "test" text))
  (void (engine-create-view! engine 1 1))
  (engine-set-view-cursor! engine 1 line #:column col)
  (define plugins (list pair-plugin indent-plugin))
  (define ed (make-editor #:engine engine
                          #:registry (make-hook-registry (plugins->hooks plugins))
                          #:plugins plugins))
  (define state (make-editor-state #:plugin-states (plugins->states plugins)))
  (values engine ed state))

;;; pair：输入开括号补闭括号
(define-values (e1 ed1 s1) (make-test-editor "" 0 0))
(define-values (s1* _a) (editor-insert! ed1 s1 1 "("))
(check-equal? (engine-view-text e1 1) "()")
(check-equal? (engine-view-point-column e1 1) 1)

;;; pair：空配对中间 backspace 删一对
(define-values (s1** _a2) (editor-delete! ed1 s1* 1 'backspace))
(check-equal? (engine-view-text e1 1) "")
;; 一次 backspace 删一对 = 一个 undo step。
(define-values (_s1*** _a2b) (editor-undo! ed1 s1** 1))
(check-equal? (engine-view-text e1 1) "()")

;;; pair：Delete 在开括号上删一对
(define-values (e2 ed2 s2) (make-test-editor "()" 0 0))
(define-values (_s2* _a3) (editor-delete! ed2 s2 1 'delete))
(check-equal? (engine-view-text e2 1) "")

;;; indent：保留当前行前导空白，行尾是开括号时再加两格
(define-values (e3 ed3 s3) (make-test-editor "  (" 0 3))
(define-values (_s3* _a4) (editor-insert! ed3 s3 1 "\n"))
(check-equal? (engine-view-text e3 1) "  (\n    ")
(check-equal? (engine-view-point-line e3 1) 1)
(check-equal? (engine-view-point-column e3 1) 4)

;;; indent：普通行只保留前导空白
(define-values (e4 ed4 s4) (make-test-editor "  foo" 0 5))
(define-values (_s4* _a5) (editor-insert! ed4 s4 1 "\n"))
(check-equal? (engine-view-text e4 1) "  foo\n  ")

(displayln "edit-tui-rebuild/test/plugins.rkt: ok")

#lang racket

;;; pair / indent 两个正式插件。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../plugins/pair/plugin.rkt"
         "../plugins/indent/plugin.rkt")

(define (make-test-editor text line col [path "test.rkt"])
  (define engine (make-engine))
  (void (engine-create-buffer! engine 1 "test" text))
  (void (engine-create-view! engine 1 1))
  (engine-set-view-cursor! engine 1 line #:column col)
  (define plugins (list pair-plugin indent-plugin))
  (define ed (make-editor #:engine engine
                          #:registry (make-hook-registry (plugins->hooks plugins))
                          #:plugins plugins))
  (define mode (doc-mode-for path text))
  (define r (make-resource 1 1 (resource-normalize-path path) "test"
                           (list 1) mode (engine-doc-version engine 1)))
  (define state (make-app-state
                 #:plugin-states (plugins->states plugins)
                 #:resources (resources-add empty-resources r)))
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

;;; indent：Racket 文本使用 racket-indent-for-newline
(define-values (e3 ed3 s3)
  (make-test-editor "#lang racket\n  (" 1 3))
(define-values (_s3* _a4) (editor-insert! ed3 s3 1 "\n"))
(check-equal? (engine-view-text e3 1) "#lang racket\n  (\n    ")
(check-equal? (engine-view-point-line e3 1) 2)
(check-equal? (engine-view-point-column e3 1) 4)

;;; indent：普通行不额外缩进
(define-values (e4 ed4 s4)
  (make-test-editor "#lang racket\n  foo" 1 5))
(define-values (_s4* _a5) (editor-insert! ed4 s4 1 "\n"))
(check-equal? (engine-view-text e4 1) "#lang racket\n  foo\n")

;;; 非 Racket 文本：只插入普通换行
(define-values (e5 ed5 s5) (make-test-editor "  (" 0 3 "test.txt"))
(define-values (_s5* _a6) (editor-insert! ed5 s5 1 "\n"))
(check-equal? (engine-view-text e5 1) "  (\n")

;;; text mode 不自动配对
(define-values (e6 ed6 s6) (make-test-editor "" 0 0 "test.txt"))
(define-values (_s6* _a7) (editor-insert! ed6 s6 1 "("))
(check-equal? (engine-view-text e6 1) "(")

(displayln "edit-tui-rebuild/test/plugins.rkt: ok")

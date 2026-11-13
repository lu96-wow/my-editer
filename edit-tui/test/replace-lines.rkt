#lang racket

;;; editor-replace-lines!：程序化整行替换
;;;   · 不跑 insert/delete before hooks
;;;   · 一个 undo step
;;;   · 进入 changes 流
;;;   · 只允许 user doc

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../plugins/pair/plugin.rkt")

(define changes-seen (box '()))

(define probe-plugin
  (make-plugin
   #:id 'probe
   #:state #t
   #:hooks
   (list
    (make-hook #:owner 'probe
               #:id 'changes
               #:operation 'changes
               #:phase 'derive
               #:fn
               (lambda (ctx ps)
                 (set-box! changes-seen
                           (cons (change-context-changes ctx)
                                 (unbox changes-seen)))
                 (values ctx ps '() #t))))))

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test.rkt" "a\nb\nc"))
(void (engine-create-view! engine 1 1))
(define plugins (list pair-plugin probe-plugin))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry (plugins->hooks plugins))
                        #:plugins plugins))
(define r (make-resource 1 1 (resource-normalize-path "test.rkt") "test"
                         (list 1) 'racket (engine-doc-version engine 1)))
(define state
  (make-app-state
   #:plugin-states (plugins->states plugins)
   #:resources (resources-add empty-resources r)))

;; 替换第 1 行；pair 不应把 "(" 自动补成 "()"。
(define-values (state1 _a1)
  (editor-replace-lines! ed state 1 1 2 (list "(")))
(check-equal? (engine-view-text engine 1) "a\n(\nc")
(check-true (pair? (unbox changes-seen)))

;; 一次 undo 回退整次替换。
(define-values (state2 _a2) (editor-undo! ed state1 1))
(check-equal? (engine-view-text engine 1) "a\nb\nc")

;; 行数增加。
(define-values (state3 _a3)
  (editor-replace-lines! ed state2 1 1 2 (list "B1" "B2")))
(check-equal? (engine-view-text engine 1) "a\nB1\nB2\nc")

;; 行数减少。
(define-values (state4 _a4)
  (editor-replace-lines! ed state3 1 1 3 (list)))
(check-equal? (engine-view-text engine 1) "a\nc")

;; 非法行号：不写，flash。
(define-values (state5 _a5)
  (editor-replace-lines! ed state4 1 9 10 (list "x")))
(check-equal? (engine-view-text engine 1) "a\nc")
(check-true (string-contains? (state-flash state5) "replace-lines"))

;; derived view 不能走 user-doc 的程序化替换。
(void (engine-create-derived-buffer! engine 10 "mirror" "d"
                                    #:owner 'test
                                    #:source-doc-id 1
                                    #:edit-policy 'intent))
(void (engine-create-view! engine 10 10))
(define-values (state6 _a6)
  (editor-replace-lines! ed state5 10 0 1 (list "x")))
(check-equal? (engine-view-text engine 10) "d")
(check-true (string-contains? (state-flash state6) "replace-lines"))

(displayln "edit-tui/test/replace-lines.rkt: ok")

#lang racket

;;; 扩展点 / pipeline 的最小回归：
;;;   - before hook 可以变换 ctx
;;;   - plugin-state 按 hook 顺序线程化
;;;   - after hook 可以产生 action
;;;   - before 返回 #f 可以否决操作

(require rackunit
         racket/string
         "../editor/host-api.rkt")

(define (make-test-editor hooks)
  (define engine (make-engine))
  (void (engine-create-buffer! engine 1 "test" ""))
  (void (engine-create-view! engine 1 1))
  (define p (make-plugin #:id 'test #:state 0 #:hooks hooks))
  (define ed (make-editor #:engine engine
                          #:registry (make-hook-registry hooks)
                          #:plugins (list p)))
  (define state (make-app-state #:plugin-states (plugins->states (list p))))
  (values engine ed state))

;;; 1. transform + state threading + after action

(define (before-double ctx ps)
  (values (struct-copy edit-context ctx
                       [text (string-append (edit-context-text ctx) "!")])
          (add1 ps)
          '()
          #t))

(define (after-note ctx ps)
  (values ctx (add1 ps) (list (flash-action "after-ran")) #t))

(define-values (engine1 ed1 state1)
  (make-test-editor
   (list (make-hook #:owner 'test #:id 'b #:operation 'insert #:phase 'transform
                    #:fn before-double)
         (make-hook #:owner 'test #:id 'a #:operation 'insert #:phase 'observe
                    #:fn after-note))))

(define-values (state1* actions1)
  (editor-insert! ed1 state1 1 "x"))

(check-equal? (engine-view-text engine1 1) "x!")
(check-equal? (state-plugin-state state1* 'test) 2)
(check-equal? (map flash-action-message actions1) '("after-ran"))

;;; 2. before 返回 #f：不提交、不跑 after

(define (before-veto ctx ps)
  (values ctx (add1 ps) (list (flash-action "vetoed")) #f))

(define (after-must-not-run ctx ps)
  (error 'after-must-not-run "after hook 不应在否决后执行"))

(define-values (engine2 ed2 state2)
  (make-test-editor
   (list (make-hook #:owner 'test #:id 'veto #:operation 'insert #:phase 'transform
                    #:fn before-veto)
         (make-hook #:owner 'test #:id 'after #:operation 'insert #:phase 'observe
                    #:fn after-must-not-run))))

(define-values (state2* actions2)
  (editor-insert! ed2 state2 1 "x"))

(check-equal? (engine-view-text engine2 1) "")
(check-equal? (state-plugin-state state2* 'test) 1)
(check-equal? (map flash-action-message actions2) '("vetoed"))

;;; 3. 顺序：priority 小者先；同 priority 按注册顺序

(define order (box '()))
(define (record name)
  (lambda (ctx ps)
    (set-box! order (append (unbox order) (list name)))
    (values ctx ps '() #t)))

(define-values (_engine3 ed3 state3)
  (make-test-editor
   (list (make-hook #:owner 'test #:id 'late #:operation 'insert #:phase 'transform
                    #:priority 20 #:fn (record 'late))
         (make-hook #:owner 'test #:id 'early #:operation 'insert #:phase 'transform
                    #:priority 10 #:fn (record 'early))
         (make-hook #:owner 'test #:id 'same #:operation 'insert #:phase 'transform
                    #:priority 10 #:fn (record 'same)))))

(define-values (_s3 _a3) (editor-insert! ed3 state3 1 "x"))
(check-equal? (unbox order) '(early same late))

;;; 4. 'changes 批次扩展点：insert 成功后跑一次，带 doc-id / version / changes

(define (observe-changes ctx ps)
  (check-true (change-context? ctx))
  (check-true (pair? (change-context-changes ctx)))
  (check-not-false (change-context-doc-id ctx))
  (check-not-false (change-context-version ctx))
  (values ctx (add1 ps) (list (flash-action "changes-seen")) #t))

(define-values (engine4 ed4 state4)
  (make-test-editor
   (list (make-hook #:owner 'test #:id 'changes #:operation 'changes
                    #:phase 'observe #:fn observe-changes))))

(define-values (state4* actions4)
  (editor-insert! ed4 state4 1 "x"))
(check-equal? (engine-view-text engine4 1) "x")
(check-equal? (state-plugin-state state4* 'test) 1)
(check-equal? (map flash-action-message actions4) '("changes-seen"))

;;; 5. 插入点 / owner 校验

(check-exn exn:fail? (λ () (make-hook #:owner 'test #:id 'bad
                                       #:operation 'not-a-point
                                       #:phase 'transform
                                       #:fn (λ (ctx ps) (values ctx ps '() #t)))))
(check-exn exn:fail? (λ () (make-hook #:owner 'test #:id 'bad-phase
                                       #:operation 'insert
                                       #:phase 'weird
                                       #:fn (λ (ctx ps) (values ctx ps '() #t)))))
(check-exn exn:fail? (λ () (make-plugin
                            #:id 'test
                            #:hooks (list (make-hook #:owner 'other
                                                     #:id 'bad-owner
                                                     #:operation 'insert
                                                     #:phase 'transform
                                                     #:fn (λ (ctx ps) (values ctx ps '() #t)))))))

(displayln "edit-tui-rebuild/test/hooks.rkt: ok")

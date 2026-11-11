#lang racket

;;; layout 扩展点：validate 可以否决 split；observe 可以观察并改 plugin-state。

(require rackunit
         "../editor/host-api.rkt"
         "../host/layout.rkt")

(define (make-test-editor hooks)
  (define engine (make-engine))
  (void (engine-create-buffer! engine 1 "test" "hello"))
  (void (engine-create-view! engine 1 1))
  (void (engine-create-buffer! engine 2 "*status*" ""))
  (void (engine-create-view! engine 2 2))
  (define p (make-plugin #:id 'layout-test #:state 0 #:hooks hooks))
  (define ed (make-editor #:engine engine
                          #:registry (make-hook-registry hooks)
                          #:plugins (list p)))
  (define layout (make-editor-layout #:editor-view 1 #:status-view 2))
  (define state
    (make-editor-state #:plugin-states (plugins->states (list p))
                       #:area (rect 0 0 40 10)
                       #:layout layout
                       #:layout-config rebuild-layout-config
                       #:next-view-id 10
                       #:next-panel-id 100))
  (values engine ed state))

;;; 1. validate 否决：不创建 panel / view
(define (veto ctx ps)
  (values ctx (add1 ps) '() #f))

(define-values (engine1 ed1 state1)
  (make-test-editor
   (list (make-hook #:owner 'layout-test #:id 'veto
                    #:operation 'layout-split #:phase 'validate
                    #:fn veto))))

(define-values (state1* _a1) (editor-split! ed1 state1 'right))
(check-equal? (length (editor-visible-editor-panels state1*)) 1)
(check-false (engine-view-object engine1 10))
(check-equal? (editor-state-plugin-state state1* 'layout-test) 1)

;;; 2. observe：split 成功后观察，plugin-state 前进
(define (observe ctx ps)
  (values ctx (add1 ps) (list (flash-action "split-observed")) #t))

(define-values (engine2 ed2 state2)
  (make-test-editor
   (list (make-hook #:owner 'layout-test #:id 'observe
                    #:operation 'layout-split #:phase 'observe
                    #:fn observe))))

(define-values (state2* actions2) (editor-split! ed2 state2 'right))
(check-equal? (length (editor-visible-editor-panels state2*)) 2)
(check-not-false (engine-view-object engine2 10))
(check-equal? (editor-state-plugin-state state2* 'layout-test) 1)
(check-equal? (map flash-action-message actions2) '("split-observed"))

(displayln "edit-tui-rebuild/test/layout.rkt: ok")

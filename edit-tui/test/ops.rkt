#lang racket

;;; 操作面 / 裸 API 的区别：
;;;   surface-insert! 跑 hook；raw-insert! 不跑。
;;; 以及 undo/redo 仍然由 core 历史负责。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../editor/ops/raw.rkt"
         "../plugins/pair/plugin.rkt")

(define (make-editor-with-pair)
  (define engine (make-engine))
  (void (engine-create-buffer! engine 1 "test" ""))
  (void (engine-create-view! engine 1 1))
  (define plugins (list pair-plugin))
  (define ed (make-editor #:engine engine
                          #:registry (make-hook-registry (plugins->hooks plugins))
                          #:plugins plugins))
  (define r (make-resource 1 1 (resource-normalize-path "test.rkt") "test"
                           (list 1) 'racket (engine-doc-version engine 1)))
  (define state (make-app-state
                 #:plugin-states (plugins->states plugins)
                 #:resources (resources-add empty-resources r)))
  (values engine ed state))

;;; 1. surface 走 hook：pair 自动补全
(define-values (engine1 ed1 state1) (make-editor-with-pair))
(define-values (state1* _a1) (editor-insert! ed1 state1 1 "("))
(check-equal? (engine-view-text engine1 1) "()")
(check-equal? (engine-view-point-column engine1 1) 1)

;;; 2. raw 不走 hook：只插入一个 "("
(define-values (engine2 _ed2 _state2) (make-editor-with-pair))
(void (raw-insert! engine2 1 "("))
(check-equal? (engine-view-text engine2 1) "(")

;;; 3. undo / redo 走 core 历史
(define-values (state3* _a3) (editor-insert! ed1 state1* 1 "x"))
(check-equal? (engine-view-text engine1 1) "(x)")
(define-values (state4 _a4) (editor-undo! ed1 state3* 1))
(check-equal? (engine-view-text engine1 1) "()")
(define-values (_state5 _a5) (editor-redo! ed1 state4 1))
(check-equal? (engine-view-text engine1 1) "(x)")

(displayln "edit-tui/test/ops.rkt: ok")

#lang racket

;;; C color async：和 Racket color 共用 host/face-jobs 单 worker。

(require rackunit
         "../editor/host-api.rkt"
         "../app/layout.rkt"
         "../host/face-jobs.rkt"
         "../plugins/c-color/plugin.rkt"
         "../lang/c/api.rkt")

(define text "#include <stdio.h>\nint main(void) { return 0; }\n")
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test.c" text))
(void (engine-create-view! engine 1 1))

(define plugin c-color-plugin)
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry (plugins->hooks (list plugin)))
                        #:plugins (list plugin)))
(define layout (make-editor-layout #:editor-view 1))
(define r (make-resource 1 1 (resource-normalize-path "test.c") "test"
                         (list 1) 'c (engine-doc-version engine 1)))
(define state
  (make-app-state #:plugin-states (plugins->states (list plugin))
                  #:screen (rect 0 0 60 10)
                  #:layout layout
                  #:resources (resources-add empty-resources r)
                  #:async? #t))

(define face-runtime (start-face-runtime))
(define (wait-paint!)
  (check-not-false (sync/timeout 2 (face-runtime-paint-channel face-runtime)))
  (face-runtime-consume-paint! face-runtime))

(parameterize ([current-face-submit (face-runtime-submit face-runtime)])
  (define s1 (run-plugin-syncs ed state))
  (wait-paint!)
  (check-not-false (engine-view-face-at engine 1 0 2))
  (check-not-false (engine-view-face-at engine 1 1 0))

  (define-values (s2 _a2) (editor-insert! ed s1 1 " "))
  (run-plugin-syncs ed s2)
  (wait-paint!)
  (check-not-false (engine-view-face-at engine 1 1 1)))

(stop-face-runtime face-runtime)
(displayln "edit-tui/test/c-color-async.rkt: ok")

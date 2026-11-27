#lang racket

;;; color async：face worker 直接写 core 属性，完成后只发 paint signal。

(require rackunit
         "../editor/host-api.rkt"
         "../app/layout.rkt"
         "../host/face-jobs.rkt"
         "../plugins/racket-color/plugin.rkt"
         "../core/face/api.rkt")

(define text "#lang racket\n(define foo foo) ; note\n")
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test.rkt" text))
(void (engine-create-view! engine 1 1))
(engine-set-view-cursor! engine 1 1 #:column 0)

(define plugin racket-color-plugin)
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry (plugins->hooks (list plugin)))
                        #:plugins (list plugin)))
(define layout (make-editor-layout #:editor-view 1))
(define r (make-resource 1 1 (resource-normalize-path "test.rkt") "test"
                         (list 1) 'racket (engine-doc-version engine 1)))
(define state
  (make-app-state #:plugin-states (plugins->states (list plugin))
                  #:screen (rect 0 0 60 10)
                  #:layout layout
                  #:resources (resources-add empty-resources r)
                  #:async? #t))

(define face-runtime (start-face-runtime))

(define (wait-paint!)
  (define v (sync/timeout 2 (face-runtime-paint-channel face-runtime)))
  (check-not-false v)
  (face-runtime-consume-paint! face-runtime))

(parameterize ([current-face-submit (face-runtime-submit face-runtime)])
  (define s1 (run-plugin-syncs ed state))
  (wait-paint!)
  ;; 注释 / 普通词 / 关键字都由 worker 直接写到 buffer face。
  (check-not-false (engine-view-face-at engine 1 1 1))
  (check-not-false (engine-view-face-at engine 1 1 12))
  (check-not-false (engine-view-face-at engine 1 1 17))

  ;; 光标进入第一个 foo：worker 重算 suppress，第一个 foo 的 word-color 消失。
  (engine-set-view-cursor! engine 1 1 #:column 8)
  (define s2 (run-plugin-syncs ed s1))
  (wait-paint!)
  (check-false (face-fg (engine-view-face-at engine 1 1 8)))

  ;; 文本编辑：changes hook 提交 edit job，新文本的 face 也要更新。
  (define-values (s3 _actions) (editor-insert! ed s2 1 " "))
  (define s4 (run-plugin-syncs ed s3))
  (wait-paint!)
  (check-not-false (engine-view-face-at engine 1 1 2))
  (void s4))

(stop-face-runtime face-runtime)
(displayln "edit-tui/test/color-async.rkt: ok")

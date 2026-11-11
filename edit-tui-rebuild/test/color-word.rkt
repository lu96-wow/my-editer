#lang racket

;;; word-color 光标 token 抑制：光标 token 内 fg 被抑制，移开后恢复。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../host/layout.rkt"
         "../plugins/racket-color/plugin.rkt"
         "../../edit-tui/core/face/api.rkt")

(define text "(define foo foo)\n")
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test.rkt" text))
(void (engine-create-view! engine 1 1))

(define plugin racket-color-plugin)
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry (plugins->hooks (list plugin)))
                        #:plugins (list plugin)))
(define layout (make-editor-layout #:editor-view 1))
(define r (make-resource 1 1 (resource-normalize-path "test.rkt") "test"
                         (list 1) 'racket (engine-doc-version engine 1)))
(define state (make-app-state #:plugin-states (plugins->states (list plugin))
                                 #:area (rect 0 0 40 10)
                                 #:layout layout
                                 #:resources (resources-add empty-resources r)))

(define s1 (run-plugin-syncs ed state))
(define f1 (engine-view-face-at engine 1 0 8))
(check-true (and f1 (symbol? (face-fg f1))
                 (string-prefix? (symbol->string (face-fg f1)) "word-color-")))

;; 光标进入第一个 foo：抑制该 token 的 word-color。
(engine-set-view-cursor! engine 1 0 #:column 8)
(define s2 (run-plugin-syncs ed s1))
(check-false (face-fg (engine-view-face-at engine 1 0 8)))

;; 光标移到第二个 foo：第一个恢复 word-color。
(engine-set-view-cursor! engine 1 0 #:column 12)
(define s3 (run-plugin-syncs ed s2))
(define f3 (engine-view-face-at engine 1 0 8))
(check-true (and f3 (symbol? (face-fg f3))
                 (string-prefix? (symbol->string (face-fg f3)) "word-color-")))

(displayln "edit-tui-rebuild/test/color-word.rkt: ok")

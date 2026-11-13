#lang racket

;;; color 增量路径：change hook 更新 color-entry；undo 也走 changes 流。

(require rackunit
         "../editor/host-api.rkt"
         "../plugins/racket-color/plugin.rkt")

(define text "#lang racket\n(define x 1)\n")
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test.rkt" text))
(void (engine-create-view! engine 1 1))
(engine-set-view-cursor! engine 1 1 #:column 0)

(define plugin racket-color-plugin)
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry (plugins->hooks (list plugin)))
                        #:plugins (list plugin)))
(define state (make-app-state #:plugin-states (plugins->states (list plugin))))

(define s1 (run-plugin-syncs ed state))
(define entry1 (hash-ref (state-plugin-state s1 'racket-color) 1))
(check-equal? (color-entry-version entry1) (engine-doc-version engine 1))
(check-not-false (engine-view-face-at engine 1 1 1))

;; 插入触发 changes hook，增量更新 color-state / face-track。
(define-values (s2 _a2) (editor-insert! ed s1 1 " "))
(define entry2 (hash-ref (state-plugin-state s2 'racket-color) 1))
(check-equal? (color-entry-version entry2) (engine-doc-version engine 1))
(define s3 (run-plugin-syncs ed s2))
(check-not-false (engine-view-face-at engine 1 1 2))

;; undo 也产生 change；changes hook 立即更新 color-entry。
(define-values (s4 _a4) (editor-undo! ed s3 1))
(define entry3 (hash-ref (state-plugin-state s4 'racket-color) 1))
(check-equal? (color-entry-version entry3) (engine-doc-version engine 1))
(define s5 (run-plugin-syncs ed s4))
(define entry4 (hash-ref (state-plugin-state s5 'racket-color) 1))
(check-equal? (color-entry-version entry4) (engine-doc-version engine 1))
(check-not-false (engine-view-face-at engine 1 1 1))

(displayln "edit-tui/test/color-incremental.rkt: ok")

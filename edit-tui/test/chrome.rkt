#lang racket

;;; 状态栏 / 输入栏：Save as prompt -> 输入 -> 写文件 -> 状态更新。
(require rackunit
         racket/file
         "../main.rkt"
         "../demo/interactive.rkt")

(define s0 (sync-ui! demo-state demo-engine))

;; 状态栏已有内容
(check-true (> (string-length (engine-view-text demo-engine 20)) 0))
(check-true (string-contains? (engine-view-text demo-engine 20) "editor"))

;; pathless resource -> Save as prompt
(define rid (app-state-focus-resource s0))
(check-equal? rid 1)
(define-values (store* acts*) (resource-save (app-state-resources s0) rid))
(check-equal? acts* '())
(check-equal? (prompt-kind (resource-prompt store*)) 'save-path)

(define s1 (struct-copy app-state s0 [resources store*]))
(define s2 (sync-ui! s1 demo-engine))
(check-true (input-active? s2))

(define path "tmp-chrome-test.txt")
(define (type-string state str)
  (for/fold ([s state]) ([c (in-string str)])
    (let-values ([(s* _a) (input-handle-key s (key-event (key c)))])
      s*)))
(define s3 (type-string s2 path))
(define s3* (sync-ui! s3 demo-engine))
(check-true (string-contains? (engine-view-text demo-engine 21) path))

(define-values (s4 actions4)
  (input-handle-key s3* (key-event (key 'enter))))
(check-equal? (map resource-action-kind actions4) '(write-file))
(define s5 (run-actions s4 demo-engine actions4))
(check-true (file-exists? path))
(check-equal? (resource-path (app-state-resources s5) rid) path)
(check-false (resource-dirty? (app-state-resources s5) rid))
(check-false (input-active? s5))

;; 状态栏显示新 path
(define s6 (sync-ui! s5 demo-engine))
(check-true (string-contains? (engine-view-text demo-engine 20) path))

(delete-file path)
(displayln "edit-tui-rebuild/test/chrome.rkt: ok")

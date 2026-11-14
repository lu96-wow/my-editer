#lang racket

;;; core error buffer：
;;;   · error log 是纯 State；
;;;   · error view 是 UI 投影；
;;;   · job-error 统一进 buffer；
;;;   · C-e 打开 panel，M-E 清空。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../editor/error.rkt"
         "../core/command/api.rkt"
         "../core/job/api.rkt"
         "../host/event.rkt"
         "../app/bootstrap.rkt"
         "../edit.rkt"
         "fixture.rkt")

(define-values (ed state0) (make-test-editor))
(define s0 (state-with-screen state0 (rect 0 0 80 24)))

;; error panel 默认隐藏。
(check-false (editor-panel-visible? s0 'errors))

;; 记录一个普通错误。
(define s1
  (state-record-error s0 'error 'sync 'demo 'frame
                      "sync failed: boom"
                      #:time 0))
(check-equal? (length (state-errors s1)) 1)
(define e1 (car (state-errors s1)))
(check-eq? (editor-error-severity e1) 'error)
(check-eq? (editor-error-source e1) 'sync)
(check-eq? (editor-error-owner e1) 'demo)
(check-equal? (editor-error-message e1) "sync failed: boom")

;; 记录异常时只保存字符串，不保存 exn 对象。
(define s2
  (state-record-exception
   s1 'error 'hook 'bad-hook 'incremental-analysis
   (exn:fail "hook boom" (current-continuation-marks))
   #:time 1))
(check-equal? (length (state-errors s2)) 2)
(check-true (string-contains? (editor-error-message (car (state-errors s2))) "hook boom"))

;; 渲染到 *errors* UI view。
(define-values (s2r _c2r _b2r) (render-frame ed s2 #f))
(define error-text (editor-view-text ed errors-vid))
(check-true (string-contains? error-text "sync failed: boom"))
(check-true (string-contains? error-text "hook boom"))
(check-true (string-contains? error-text "[ERROR]"))

;; C-e 打开 error panel。
(define s3 (handle-editor-event ed s2r (key-event (key 'e 'ctrl))))
(check-true (editor-panel-visible? s3 'errors))

;; job-error 统一记录。
(define-values (s4 job)
  (state-submit-job s3 'demo-job 'payload '(demo-tag)))
(define jev (job-result-event (job-id job) 'demo-job
                             (job-error "job service boom")
                             '(demo-tag)))
(define s5 (handle-job-result ed s4 jev))
(define job-errors
  (filter (λ (e) (eq? (editor-error-source e) 'job))
          (state-errors s5)))
(check-equal? (length job-errors) 1)
(check-true (string-contains? (editor-error-message (car job-errors))
                              "job service boom"))

;; M-E 清空。
(define s6 (handle-editor-event ed s5 (key-event (key 'E 'alt))))
(check-equal? (state-errors s6) '())
(define-values (s6r _c6r _b6r) (render-frame ed s6 #f))
(check-equal? (editor-view-text ed errors-vid) "(no errors)")

(displayln "edit-tui/test/error-buffer.rkt: ok")

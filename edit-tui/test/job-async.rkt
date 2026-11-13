#lang racket

;;; 异步 filetree scan：sync 提交 job -> worker -> result -> plugin handle -> 写 view。

(require rackunit
         racket/async-channel
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../plugins/filetree/plugin.rkt"
         "../host/jobs.rkt"
         "../edit.rkt"
         "../app/layout.rkt")

(define root (make-temporary-directory))
(display-to-file "a" (build-path root "a.txt") #:exists 'replace)

(define engine (make-engine))
(void (engine-create-buffer! engine 1 "test" ""))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 3 "*filetree*" "" #:kind 'ui))
(void (engine-create-view! engine 3 3))

(define plugin (make-filetree-plugin #:view 3 #:root root))
(define ed (make-editor #:engine engine
                        #:registry (make-hook-registry '())
                        #:plugins (list plugin)))
(define layout (make-editor-layout #:editor-view 1 #:sidebar-view 3))
(define state
  (make-app-state #:plugin-states (plugins->states (list plugin))
                     #:area (rect 0 0 60 15)
                     #:layout layout
                     #:async? #t))

;; sync 只提交 job；旧 rows 为空。
(define s1 (run-plugin-syncs ed state))
(check-equal? (length (state-pending-jobs s1)) 1)
(check-equal? (engine-view-text engine 3) "")

(define event-channel (make-async-channel))
(define rt (start-job-runtime (editor-services ed)
                              #:event-channel event-channel
                              #:workers 1))
(dispatch-jobs! rt (state-jobs s1))
(check-equal? (hash-count (job-runtime-dispatched rt)) 1)
(define ev (async-channel-get event-channel))
(check-eq? (job-result-event-kind ev) 'filetree-scan)

(define s2 (handle-job-result ed s1 ev))
(check-equal? (length (state-pending-jobs s2)) 0)
;; 已完成的 job 不在 pending 里，下一次 dispatch 会把它从 dispatched 清掉。
(dispatch-jobs! rt (state-jobs s2))
(check-equal? (hash-count (job-runtime-dispatched rt)) 0)
(stop-job-runtime rt)
(define s3 (run-plugin-syncs ed s2))
(check-true (string-contains? (engine-view-text engine 3) "a.txt"))

(delete-directory/files root)
(displayln "edit-tui/test/job-async.rkt: ok")

#lang racket

;;; workspace 异步 analysis：
;;;   · changes hook 在 async 模式只做 debounce，不分析整篇文本；
;;;   · timer 提交 workspace-analysis-edit job；
;;;   · 连续编辑会被合并，只提交最新的目标版本；
;;;   · 没有 changes 的路径（新打开文件）仍由 workspace-schedule! 提交全量 job；
;;;   · 结果按 job-id + (doc-id, version) 校验，过期结果丢弃。

(require rackunit
         racket/async-channel
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../core/job/api.rkt"
         "../lang/racket/api.rkt"
         "../host/jobs.rkt"
         "../host/open.rkt"
         "../host/timers.rkt"
         "../features/placement/api.rkt"
         "../editor/job.rkt"
         "../edit.rkt")

(define text "#lang racket\n(define (foo) 1)\n")
(define-values (ed state) (make-editor-app #:initial-text text
                                           #:initial-name "async.rkt"))
(define s0 (state-with-area (state-with-async state #t) (rect 0 0 60 15)))
(define-values (s0r _c0 _b0) (render-frame ed s0 #f))
(define initial-version (editor-doc-version ed 1))
(check-eq? (document-entry-version (workspace-doc (editor-workspace ed) 1))
           initial-version)

(define ch (make-async-channel))
(define timer-rt (start-timer-runtime #:event-channel ch))
(editor-set-timer-service! ed (timer-runtime-service timer-rt))
(define job-rt (start-job-runtime (editor-services ed)
                                  #:event-channel ch
                                  #:workers 1))

(define (next-event pred)
  (let loop ()
    (define ev (async-channel-get ch))
    (if (pred ev) ev (loop))))

(define (next-timer-event)
  (next-event timer-event?))

(define (next-job-event kind)
  (next-event (λ (ev)
                (and (job-result-event? ev)
                     (eq? (job-result-event-kind ev) kind)))))

(define (pending-jobs state kind)
  (filter (λ (j) (eq? (job-kind j) kind))
          (state-pending-jobs state)))

;;; ════════════════ changes -> debounce -> incremental job ════════════════

(define-values (sp0 _pa0) (editor-set-point! ed s0r 1 2 0))
(define-values (sp1 _pa1)
  (editor-paste! ed sp0 1
                 (string->bytes/utf-8 "(define (new-name) 1)\n")))
(define pasted-version (editor-doc-version ed 1))
(check-not-eq? pasted-version initial-version)

;; changes hook 只调度 timer；workspace 仍是旧版本。
(check-eq? (document-entry-version (workspace-doc (editor-workspace ed) 1))
           initial-version)

(define-values (sp1r _c1r _b1r) (render-frame ed sp1 #f))
(check-equal? (pending-jobs sp1r 'workspace-analysis) '())
(check-equal? (pending-jobs sp1r 'workspace-analysis-edit) '())

(define tev1 (next-timer-event))
(define-values (sp2 _ta2) (run-plugin-timer-handlers ed sp1r tev1))
(check-equal? (length (pending-jobs sp2 'workspace-analysis-edit)) 1)
(check-equal? (document-entry-version (workspace-doc (editor-workspace ed) 1))
              initial-version)

(dispatch-jobs! job-rt (state-jobs sp2))
(define jev1 (next-job-event 'workspace-analysis-edit))
(define sp3 (handle-job-result ed sp2 jev1))
(check-equal? (document-entry-version (workspace-doc (editor-workspace ed) 1))
              pasted-version)
(check-not-false
 (member 'new-name
         (module-analysis-definitions
          (workspace-analysis (editor-workspace ed) 1))))

;;; ════════════════ 连续编辑合并到最新版本 ════════════════

(define-values (sp4 _pa4) (editor-insert! ed sp3 1 " "))
(define v4 (editor-doc-version ed 1))
(define-values (sp5 _pa5)
  (editor-insert! ed sp4 1 "(define (coalesced-name) 3)\n"))
(define v5 (editor-doc-version ed 1))
(check-not-eq? v4 v5)

;; 旧 timer 被取消；workspace 仍停在 pasted-version。
(define-values (sp5r _c5r _b5r) (render-frame ed sp5 #f))
(check-equal? (document-entry-version (workspace-doc (editor-workspace ed) 1))
              pasted-version)

(define tev2 (next-timer-event))
(define-values (sp6 _ta6) (run-plugin-timer-handlers ed sp5r tev2))
(check-equal? (length (pending-jobs sp6 'workspace-analysis-edit)) 1)

(dispatch-jobs! job-rt (state-jobs sp6))
(define jev2 (next-job-event 'workspace-analysis-edit))
(define sp7 (handle-job-result ed sp6 jev2))
(check-equal? (document-entry-version (workspace-doc (editor-workspace ed) 1))
              v5)
(check-not-false
 (member 'coalesced-name
         (module-analysis-definitions
          (workspace-analysis (editor-workspace ed) 1))))

;;; ════════════════ 新打开文件：无 changes，走全量异步分析 ════════════════

(define root (make-temporary-directory))
(define extra-path (build-path root "extra.rkt"))
(display-to-file "#lang racket\n(define (extra-name) 2)\n" extra-path
                 #:exists 'replace)

(define-values (so0 _oa0) (editor-open-file! ed sp7 extra-path))
(define extra-did (editor-placement-view-id so0))
(define extra-version (editor-doc-version ed extra-did))
(check-false (workspace-doc (editor-workspace ed) extra-did))

(define-values (so1 _oa1) (editor-placement-commit ed so0))
(define-values (so2 _co2 _bo2) (render-frame ed so1 #f))
(check-equal? (length (pending-jobs so2 'workspace-analysis)) 1)
(check-false (workspace-doc (editor-workspace ed) extra-did))

(dispatch-jobs! job-rt (state-jobs so2))
(define fev (next-job-event 'workspace-analysis))
(check-equal? (job-result-event-tag fev) (list extra-did extra-version))

(define so3 (handle-job-result ed so2 fev))
(check-equal? (pending-jobs so3 'workspace-analysis) '())
(check-equal? (document-entry-version
               (workspace-doc (editor-workspace ed) extra-did))
              extra-version)
(check-not-false
 (member 'extra-name
         (module-analysis-definitions
          (workspace-analysis (editor-workspace ed) extra-did))))

;;; ════════════════ 过期结果丢弃 ════════════════

(define stale-analysis (workspace-analysis (editor-workspace ed) 1))
(define stale-ev
  (job-result-event 999 'workspace-analysis stale-analysis
                    (list 1 'stale)))
(define so4 (handle-job-result ed so3 stale-ev))
(check-equal? (document-entry-version (workspace-doc (editor-workspace ed) 1))
              v5)
(check-not-false
 (member 'coalesced-name
         (module-analysis-definitions
          (workspace-analysis (editor-workspace ed) 1))))

(stop-job-runtime job-rt)
(stop-timer-runtime timer-rt)
(delete-directory/files root)
(displayln "edit-tui/test/workspace-async.rkt: ok")

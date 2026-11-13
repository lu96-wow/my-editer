#lang racket

;;; workspace 全量 analysis 异步：
;;;   · async 模式下 workspace-sync! 不阻塞做全量分析
;;;   · workspace-schedule! 提交 workspace-analysis job
;;;   · 结果按 (doc-id, version) 校验后安装
;;;   · 过期结果丢弃

(require rackunit
         racket/async-channel
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../core/job/api.rkt"
         "../lang/racket/api.rkt"
         "../host/jobs.rkt"
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

;;; ════════════════ paste 触发 full fallback ════════════════

(define-values (sp0 _pa0) (editor-set-point! ed s0r 1 2 0))
(define-values (sp1 _pa1)
  (editor-paste! ed sp0 1
                 (string->bytes/utf-8 "(define (new-name) 1)\n")))
(define pasted-version (editor-doc-version ed 1))
(check-not-eq? pasted-version initial-version)
;; workspace 还没做全量分析。
(check-eq? (document-entry-version (workspace-doc (editor-workspace ed) 1))
           initial-version)

(define-values (sp2 _cp2 _bp2) (render-frame ed sp1 #f))
(define pending
  (filter (λ (j) (eq? (job-kind j) 'workspace-analysis))
          (state-pending-jobs sp2)))
(check-equal? (length pending) 1)
;; 旧 entry 仍然可用。
(check-eq? (document-entry-version (workspace-doc (editor-workspace ed) 1))
           initial-version)

;;; ════════════════ worker -> result -> 安装 ════════════════

(define ch (make-async-channel))
(define rt (start-job-runtime (editor-services ed)
                              #:event-channel ch
                              #:workers 1))
(dispatch-jobs! rt (state-jobs sp2))
(define (next-workspace-event)
  (let loop ()
    (define ev (async-channel-get ch))
    (if (eq? (job-result-event-kind ev) 'workspace-analysis)
        ev
        (loop))))
(define ev (next-workspace-event))
(stop-job-runtime rt)
(check-equal? (job-result-event-tag ev) (list 1 pasted-version))

(define sp3 (handle-job-result ed sp2 ev))
(check-false
 (for/or ([j (in-list (state-pending-jobs sp3))])
   (eq? (job-kind j) 'workspace-analysis)))
(check-equal? (document-entry-version (workspace-doc (editor-workspace ed) 1))
              pasted-version)
(check-not-false
 (member 'new-name
         (module-analysis-definitions
          (workspace-analysis (editor-workspace ed) 1))))

;;; ════════════════ 过期结果丢弃 ════════════════

(define stale-analysis (workspace-analysis (editor-workspace ed) 1))
(define stale-ev
  (job-result-event 999 'workspace-analysis stale-analysis
                    (list 1 'stale)))
(define sp4 (handle-job-result ed sp3 stale-ev))
(check-equal? (document-entry-version (workspace-doc (editor-workspace ed) 1))
              pasted-version)

(displayln "edit-tui/test/workspace-async.rkt: ok")

#lang racket

;;; workspace 全量 analysis 异步：
;;;   · 所有文本变更（insert / delete / paste / undo / redo / kill-line）都走
;;;     'changes 流，workspace 能增量更新，不再为 paste / undo 提交全量 job；
;;;   · 没有 changes 的路径（例如新打开的文件）由 workspace-schedule! 提交
;;;     workspace-analysis job；
;;;   · 结果按 (doc-id, version) 校验后安装，过期结果丢弃。

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

;;; ════════════════ paste 走 changes 增量，不等异步 job ════════════════

(define-values (sp0 _pa0) (editor-set-point! ed s0r 1 2 0))
(define-values (sp1 _pa1)
  (editor-paste! ed sp0 1
                 (string->bytes/utf-8 "(define (new-name) 1)\n")))
(define pasted-version (editor-doc-version ed 1))
(check-not-eq? pasted-version initial-version)
;; changes hook 已就地更新 workspace，不需要全量 job。
(check-eq? (document-entry-version (workspace-doc (editor-workspace ed) 1))
           pasted-version)
(check-not-false
 (member 'new-name
         (module-analysis-definitions
          (workspace-analysis (editor-workspace ed) 1))))

(define-values (sp2 _cp2 _bp2) (render-frame ed sp1 #f))
(check-equal?
 (filter (λ (j) (eq? (job-kind j) 'workspace-analysis))
         (state-pending-jobs sp2))
 '())

;;; ════════════════ 新打开文件：无 changes，走全量异步分析 ════════════════

(define root (make-temporary-directory))
(define extra-path (build-path root "extra.rkt"))
(display-to-file "#lang racket\n(define (extra-name) 2)\n" extra-path
                 #:exists 'replace)

(define-values (so0 _oa0) (editor-open-file! ed sp2 extra-path))
(define extra-did (editor-placement-view-id so0))
(define extra-version (editor-doc-version ed extra-did))
(check-false (workspace-doc (editor-workspace ed) extra-did))

(define-values (so1 _oa1) (editor-placement-commit ed so0))
(define-values (so2 _co2 _bo2) (render-frame ed so1 #f))
(define pending
  (filter (λ (j) (eq? (job-kind j) 'workspace-analysis))
          (state-pending-jobs so2)))
(check-equal? (length pending) 1)
;; 旧 workspace 仍然可用；新文件 entry 等 worker 结果。
(check-false (workspace-doc (editor-workspace ed) extra-did))

;;; ════════════════ worker -> result -> 安装 ════════════════

(define ch (make-async-channel))
(define rt (start-job-runtime (editor-services ed)
                              #:event-channel ch
                              #:workers 1))
(dispatch-jobs! rt (state-jobs so2))
(define (next-workspace-event)
  (let loop ()
    (define ev (async-channel-get ch))
    (if (eq? (job-result-event-kind ev) 'workspace-analysis)
        ev
        (loop))))
(define ev (next-workspace-event))
(stop-job-runtime rt)
(check-equal? (job-result-event-tag ev) (list extra-did extra-version))

(define so3 (handle-job-result ed so2 ev))
(check-false
 (for/or ([j (in-list (state-pending-jobs so3))])
   (eq? (job-kind j) 'workspace-analysis)))
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
              pasted-version)

(delete-directory/files root)
(displayln "edit-tui/test/workspace-async.rkt: ok")

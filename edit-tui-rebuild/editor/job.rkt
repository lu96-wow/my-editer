#lang racket

;;; edit-tui-rebuild/editor/job.rkt —— 异步 job 的 State 层
;;;
;;; 纯账本在 core/job；这里只把它放进 editor-state，并定义 host -> plugin
;;; 传递结果的 job-result-event。

(require "../core/job/api.rkt"
         "state.rkt")

(provide (struct-out job-result-event)
         editor-state-submit-job
         editor-state-finish-job
         editor-state-forget-job
         editor-state-pending-jobs)

(struct job-result-event (id kind result tag) #:transparent)

(define (editor-state-submit-job state kind payload [tag #f])
  (define-values (ledger j)
    (job-submit (editor-state-jobs state) kind payload tag))
  (values (editor-state-with-jobs state ledger) j))

(define (editor-state-finish-job state id result)
  (define ledger (job-finish (editor-state-jobs state) id result))
  (if (eq? ledger (editor-state-jobs state))
      state
      (editor-state-with-jobs state ledger)))

(define (editor-state-forget-job state id)
  (define ledger (job-forget (editor-state-jobs state) id))
  (if (eq? ledger (editor-state-jobs state))
      state
      (editor-state-with-jobs state ledger)))

(define (editor-state-pending-jobs state)
  (job-pending (editor-state-jobs state)))

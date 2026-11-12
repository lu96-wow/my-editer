#lang racket

;;; edit-tui/editor/job.rkt —— 异步 job 的 State 层
;;;
;;; 纯账本在 core/job；这里只把它放进 editor-state，并定义 host -> plugin
;;; 传递结果的 job-result-event。

(require "../core/job/api.rkt"
         "state.rkt")

(provide (struct-out job-result-event)
         state-submit-job
         state-finish-job
         state-forget-job
         state-pending-jobs)

(struct job-result-event (id kind result tag) #:transparent)

(define (state-submit-job state kind payload [tag #f])
  (define-values (ledger j)
    (job-submit (state-jobs state) kind payload tag))
  (values (state-with-jobs state ledger) j))

(define (state-finish-job state id result)
  (define ledger (job-finish (state-jobs state) id result))
  (if (eq? ledger (state-jobs state))
      state
      (state-with-jobs state ledger)))

(define (state-forget-job state id)
  (define ledger (job-forget (state-jobs state) id))
  (if (eq? ledger (state-jobs state))
      state
      (state-with-jobs state ledger)))

(define (state-pending-jobs state)
  (job-pending (state-jobs state)))

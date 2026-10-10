#lang racket

;;; edit/plugin/builtin/doc-worker.rkt —— place worker：算一个标识符的文档
;;;
;;; 只做一件事：`(doc name mods)` → bluebox 优先 / HTML 兜底的文档（lang/docs）。
;;; 由 doc-job 的 runner 调用；补全的 worker 不认识文档。

(require racket/match
         "../runner.rkt"
         "../../lang/docs.rkt")

(provide main)

(define (main ch)
  (job-worker-main
   ch
   (lambda (req)
     (match req
       [(list 'doc name mods) (doc->result (docs-for name #:modules mods))]
       [_ #f]))))

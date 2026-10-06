#lang racket

(require racket/match
         (prefix-in job: "../platform/job.rkt")
         "lang/docs.rkt")

;;; lab-rebuild/builtin/doc-worker.rkt —— 后台查文档 place 入口
;;;
;;; 收 (name mods) → 回 #f | (list name signature)。xref / bluebox 缓存在本进程内。

(provide worker-main)

(define (worker-main ch)
  (job:job-worker-main
   ch
   (lambda (req)
     (match-define (list name mods) req)
     (define d (docs-for name #:modules mods))
     (and d (list (doc-name d) (doc-signature d))))))

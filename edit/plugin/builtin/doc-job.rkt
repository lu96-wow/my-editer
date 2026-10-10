#lang racket

;;; edit/plugin/builtin/doc-job.rkt —— 异步查文档服务（传输）
;;;
;;; 把「提交一个标识符的文档查询、异步取回」从文档浮窗业务里拆出来，供任意特性复用：
;;;   doc-request!  提交请求 → req-id（配合 session-await 做版本闸门）
;;;   install-doc-job!  建服务 + 注册 before-render 轮询钩子
;;;
;;; 传输：place worker（doc-worker.rkt），首次请求时惰性创建（place 需在 with-tui 后建）。
;;; 结果统一包成 job-result（job-result #t 值 / job-result #f 错误串）。

(require racket/runtime-path
         "../registry.rkt"
         "../runner.rkt"
         "../../feature/api.rkt")

(provide install-doc-job! doc-request!)

(struct doc-svc (runner) #:transparent)
;; runner : box (runner | #f)

(define-runtime-path worker-path "doc-worker.rkt")

(define (doc-svc-of s) (session-service-ref s 'doc-job))

(define (ensure-runner svc)
  (or (unbox (doc-svc-runner svc))
      (let ([r (make-place-runner worker-path 'main #:wake async-wake)])
        (set-box! (doc-svc-runner svc) r)
        r)))

;; 提交一次文档查询。name : string，mods : (listof module-path)。
(define (doc-request! s name mods)
  (runner-submit! (ensure-runner (doc-svc-of s)) (list 'doc name mods)))

;; before-render：轮询 worker，把到齐的结果交给闸门（session-deliver 会跑 on-result）。
(define (doc-poll-hook s _args)
  (define svc (doc-svc-of s))
  (define r (and svc (unbox (doc-svc-runner svc))))
  (cond
    [(not r) s]
    [else
     (for/fold ([s s]) ([m (in-list (runner-poll! r))])
       (define res (cdr m))
       (cond
         [(job-result-ok? res) (session-deliver s (car m) (job-result-value res))]
         [else (session-deliver (session-log! s (format "doc worker: ~a" (job-result-value res)))
                                (car m) '())]))]))

(define (install-doc-job! s)
  (session-add-hook
   (session-service-put s 'doc-job (doc-svc (box #f)))
   (hook 'before-render doc-poll-hook)))

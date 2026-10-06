#lang racket

;;; lab-rebuild/builtin/doc-job.rkt —— 异步查文档服务（惰性起 place）。
;;;
;;; 传输归特性：这里只做「submit + poll → 交给内核闸门」。
;;; ⚠ place 只能在 with-tui 之后建：runner 惰性创建（注册 source / 首次请求时）。
;;; 同步后端（smoke / 无后台）回落 sync runner。

(require racket/runtime-path
         racket/match
         "../kernel/runner.rkt"
         "../kernel/effect.rkt"
         "../kernel/runtime.rkt"
         "../kernel/pipeline.rkt"
         "../kernel/registry.rkt"
         "lang/docs.rkt")

(provide register-doc-job! doc-request! doc-poll!)

(struct doc-svc (runner-box) #:transparent)

(define-runtime-path doc-worker.rkt "doc-worker.rkt")

(define (doc-handler req)
  (match-define (list name mods) req)
  (define d (docs-for name #:modules mods))
  (and d (list (doc-name d) (doc-signature d))))

(define (ensure-runner bg? svc)
  (or (unbox (doc-svc-runner-box svc))
      (let ([r (if bg? (make-place-runner doc-worker.rkt 'worker-main 1)
                   (make-sync-runner doc-handler))])
        (set-box! (doc-svc-runner-box svc) r)
        r)))

(define (doc-request! ctx name mods)
  (define svc (service-ref ctx 'doc-job))
  (define bg? (hash-ref (runtime-config (ctx-runtime ctx)) 'background? #f))
  (runner-submit! (ensure-runner bg? svc) (list name mods)))

;; → (listof effect)：把到齐的结果交给内核闸门（e-deliver）。
(define (doc-poll! ctx)
  (define svc (service-ref ctx 'doc-job))
  (define r (and svc (unbox (doc-svc-runner-box svc))))
  (cond
    [(not r) '()]
    [else
     (for/list ([msg (in-list (runner-poll! r))])
       (e-deliver (car msg) (cdr msg)))]))

(define (doc-source svc bg?)
  ((runner-source (ensure-runner bg? svc))))

(define (doc-job-init ctx)
  (define svc (doc-svc (box #f)))
  (define bg? (hash-ref (runtime-config (ctx-runtime ctx)) 'background? #f))
  (define ctx1 (service-put ctx 'doc-job svc))
  (service-add-source ctx1 (lambda () (doc-source svc bg?))))

(define (register-doc-job! r)
  (reg-add r (contrib 'init 'doc-job 0 doc-job-init)))

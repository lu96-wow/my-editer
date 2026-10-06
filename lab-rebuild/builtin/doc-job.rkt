#lang racket

(require racket/runtime-path
         "../platform/job.rkt")

;;; lab-rebuild/builtin/doc-job.rkt —— 异步查文档服务（单例，惰性起 place）
;;;
;;; ⚠ 不要在本模块加载时就创建 place：racket-tui 要求 `with-tui` 之前不能有 OS 线程
;;; （否则 signalfd 收不到 SIGWINCH）。所以 runner 惰性创建 —— 首次 request 或
;;; 后端注册 source 时（那时已在 with-tui 的 thunk 里）。
;;;
;;; 结果值 = #f | (list name signature)（不让 struct 跨 place，避免类型身份问题）。
;;; 多个消费者各自持有一个 pending id，用 doc-job-result 查；
;;; doc-job-poll! 可被重复调用（第二次抽到空，缓存仍在）。

(provide doc-job-request! doc-job-poll! doc-job-result
         doc-job-source doc-job-stop!)

(define-runtime-path worker.rkt "doc-worker.rkt")

(define runner #f)                      ; 惰性：job-runner / #f
(define results (make-hash))            ; id -> #f | (list name signature)

(define (the-runner)
  (or runner
      (begin (set! runner (make-place-job-runner worker.rkt 'worker-main)) runner)))

(define (doc-job-request! name mods) (job-submit! (the-runner) (list name mods)))

(define (doc-job-poll!)
  (when runner
    (for ([msg (in-list (job-poll! runner))])
      (hash-set! results (car msg) (cdr msg)))))

(define (doc-job-result id)
  (if (hash-has-key? results id)
      (values #t (hash-ref results id))
      (values #f #f)))

;; 后端登记结果源时才会真正起 place（那时已在 with-tui 里）。
(define (doc-job-source) (job-source (the-runner)))
(define (doc-job-stop!)
  (when runner (job-stop! runner) (set! runner #f)))

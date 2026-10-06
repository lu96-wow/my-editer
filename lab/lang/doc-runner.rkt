#lang racket

;;; lab-rebuild/lang/doc-runner.rkt —— 后台文档查询执行器（单例）
;;;
;;; 惰性起一个 place（首次请求时）。主进程只发 (id name mods)，结果经 async-channel
;;; 回来；`doc-runner-source` 给 backend 的 on-source 注册，结果到达即唤醒事件循环。
;;;
;;; 版本闸门**不在这里**：结果只带请求 id；由 core/actions/lang.rkt 检查
;;; 「请求 id 还是当前 mode 的 + 发起时的不可变 document 还是当前 document」。
;;;
;;; 抽消息顺序同 plugin/attr/runner-place.rkt：先抽 signal，再抽 mailbox。

(require racket/place
         racket/async-channel
         racket/runtime-path)

(provide doc-runner-request! doc-runner-poll! doc-runner-source doc-runner-stop!)

(define-runtime-path worker.rkt "doc-worker.rkt")

(define mailbox (make-async-channel))
(define signal (make-async-channel))
(define ch #f)                          ; place channel / #f（未启动）
(define next-id 0)

(define (ensure-started!)
  (unless ch
    (define c (dynamic-place worker.rkt 'worker-main))
    (set! ch c)
    (thread (lambda ()
              (with-handlers ([exn? (lambda (_) (void))])
                (let loop ()
                  (define msg (place-channel-get c))
                  (async-channel-put mailbox msg)
                  (async-channel-put signal 'ready)
                  (loop)))))))

;; 发一个查询，返回请求 id。
(define (doc-runner-request! name mods)
  (ensure-started!)
  (define id (begin0 next-id (set! next-id (add1 next-id))))
  (place-channel-put ch (list 'doc id name mods))
  id)

;; 非阻塞抽干结果： (listof (list id name signature))。
(define (doc-runner-poll!)
  (let drain-signal () (when (async-channel-try-get signal) (drain-signal)))
  (let loop ([acc '()])
    (define v (async-channel-try-get mailbox))
    (if v (loop (cons v acc)) (reverse acc))))

;; 后端 on-source 用（结果到达就绪）。
(define (doc-runner-source) signal)

(define (doc-runner-stop!)
  (when ch
    (with-handlers ([exn? (lambda (_) (void))])
      (place-channel-put ch 'stop))
    (set! ch #f)))

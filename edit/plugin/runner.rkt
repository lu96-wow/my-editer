#lang racket

;;; edit/plugin/runner.rkt —— 通用异步执行器（传输，feature-free）
;;;
;;; 只做「把请求丢到别处跑、按 id 取回」：
;;;   sync-runner  : handler 就地跑，结果入队（本帧即可取回）
;;;   place-runner : n 个 worker place 进程，主进程发请求、收结果（真并行）
;;; 版本闸门不在本层（由 session/async.rkt 统一）。
;;;
;;; ⚠ place 只能在 tui:with-tui 之后创建；所以服务惰性创建 runner
;;;   （首次请求时），不要启动期就建。

(require racket/async-channel
         racket/place
         racket/match)

(provide (struct-out runner)
         make-sync-runner make-place-runner job-worker-main
         runner-submit! runner-poll! runner-stop!)

(struct runner (submit poll stop) #:transparent)

(define (runner-submit! r request) ((runner-submit r) request))
(define (runner-poll! r) ((runner-poll r)))
(define (runner-stop! r) ((runner-stop r)))

;;; ================= 同步 =================

(define (make-sync-runner handler)
  (define q (box '()))
  (define next-id 0)
  (runner
   (lambda (request)
     (define id (begin0 next-id (set! next-id (add1 next-id))))
     (define result (with-handlers ([exn? (lambda (_) #f)]) (handler request)))
     (set-box! q (cons (cons id result) (unbox q)))
     id)
   (lambda () (begin0 (reverse (unbox q)) (set-box! q '())))
   (lambda () (void))))

;;; ================= place =================

(define (make-place-runner worker-path worker-main [n 1])
  (define mailbox (make-async-channel))
  (define signal (make-async-channel))
  (define workers
    (for/list ([_ (in-range (max 1 n))]) (dynamic-place worker-path worker-main)))
  (for ([w (in-list workers)])
    (thread (lambda ()
              (with-handlers ([exn? (lambda (_) (void))])
                (let loop ()
                  (define msg (place-channel-get w))
                  (async-channel-put mailbox msg)
                  (async-channel-put signal 'ready)
                  (loop))))))
  (define ws (list->vector workers))
  (define next-id 0)
  (define (worker-for id) (vector-ref ws (modulo id (vector-length ws))))
  (runner
   (lambda (request)
     (define id (begin0 next-id (set! next-id (add1 next-id))))
     (place-channel-put (worker-for id) (cons id request))
     id)
   (lambda ()
     ;; ⚠ 先抽 signal，再抽 mailbox（否则会抹掉后到消息的唤醒）。
     (let drain-signal () (when (async-channel-try-get signal) (drain-signal)))
     (let loop ([acc '()])
       (define v (async-channel-try-get mailbox))
       (if v (loop (cons v acc)) (reverse acc))))
   (lambda ()
     (for ([p (in-list workers)])
       (with-handlers ([exn? (lambda (_) (void))]) (place-channel-put p 'stop))))))

;;; ================= worker 入口助手 =================

(define (job-worker-main ch handler)
  (let loop ()
    (define msg (place-channel-get ch))
    (cond
      [(eq? msg 'stop) (void)]
      [else
       (match-define (cons id request) msg)
       (define result (with-handlers ([exn? (lambda (_) #f)]) (handler request)))
       (place-channel-put ch (cons id result))
       (loop)])))

#lang racket

(require racket/async-channel
         racket/place
         racket/match)

;;; lab-rebuild/platform/job.rkt —— 统一异步任务执行器（平台扩展点）
;;;
;;; 把「把一段纯计算丢到别处跑、结果按 id 取回」抽象成 job-runner，两种实现：
;;;   · sync-runner  ：handler 就地跑，结果进队列（测试 / 轻量任务）
;;;   · place-runner ：n 个 worker place，主进程只发请求、收结果
;;;
;;; 接口：
;;;   (job-submit! r request) -> id       发一个请求，返回自增 id
;;;   (job-poll!   r)         -> (listof (cons id result))   非阻塞抽干
;;;   (job-source  r)         -> evt? / #f  结果到达就绪（后端 on-source）
;;;   (job-stop!   r)         -> void
;;;
;;; worker 侧协议（只在 place-runner 用）：
;;;   worker 收 (cons id request)，回 (cons id result)；收 'stop 退出。
;;;   place worker 的入口可以是一行 —— 用 job-worker-main：
;;;     (define (worker-main ch) (job-worker-main ch handler))
;;;   handler 在 worker 里跑，异常 → #f（不让 worker 崩）。
;;;
;;; ⚠ 创建时机：只能在 **tui:with-tui 内部** 调 make-place-job-runner。
;;;   place / futures 会建 OS 线程，而 racket-tui 的 resize 监控（signalfd）要求
;;;   with-tui 之前没有未阻塞 SIGWINCH 的 OS 线程，否则收不到 SIGWINCH。
;;;   所以服务模块不要顶层创建 runner，惰性到首次请求 / 后端登记 source 时再建
;;;   （那时已在 with-tui 的 thunk 里）。
;;;
;;; 版本闸门不在这里：结果只带 id，由调用方检查「id 还是当前的」「发起时的
;;; document 还是当前的」。这样 runner 保持纯粹。

(provide (struct-out job-runner)
         make-sync-job-runner make-place-job-runner job-worker-main
         job-submit! job-poll! job-source job-stop!)

(struct job-runner (submit poll source stop) #:transparent)

(define (job-submit! r request) ((job-runner-submit r) request))
(define (job-poll! r) ((job-runner-poll r)))
(define (job-source r) ((job-runner-source r)))
(define (job-stop! r) ((job-runner-stop r)))

;;; ================= 同步实现 =================

(define (make-sync-job-runner handler)
  (define q (box '()))
  (define next-id 0)
  (job-runner
   (lambda (request)
     (define id (begin0 next-id (set! next-id (add1 next-id))))
     (define result (with-handlers ([exn? (lambda (_) #f)]) (handler request)))
     (set-box! q (cons (cons id result) (unbox q)))
     id)
   (lambda () (begin0 (reverse (unbox q)) (set-box! q '())))
   (lambda () #f)
   (lambda () (void))))

;;; ================= place 实现 =================

;; worker-path : 运行时路径（调用方用 define-runtime-path 解析）；worker-main : symbol
(define (make-place-job-runner worker-path worker-main [n 1])
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
  (job-runner
   (lambda (request)
     (define id (begin0 next-id (set! next-id (add1 next-id))))
     (place-channel-put (worker-for id) (cons id request))
     id)
   (lambda ()
     ;; ⚠ 顺序要紧：先抽 signal，再抽 mailbox（否则会抹掉后到消息的唤醒）。
     (let drain-signal () (when (async-channel-try-get signal) (drain-signal)))
     (let loop ([acc '()])
       (define v (async-channel-try-get mailbox))
       (if v (loop (cons v acc)) (reverse acc))))
   (lambda () signal)
   (lambda ()
     (for ([p (in-list workers)])
       (with-handlers ([exn? (lambda (_) (void))]) (place-channel-put p 'stop))))))

;;; ================= worker 入口助手 =================
;;; handler : request -> result。worker-main 里一行接上即可。
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

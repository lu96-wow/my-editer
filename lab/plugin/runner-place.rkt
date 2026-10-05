#lang racket

(require racket/runtime-path
         racket/async-channel
         "runner.rkt")

;;; lab/plugin/runner-place.rkt —— 后台 place 进程执行器
;;;
;;; 起 n 个 worker place。**按 did 固定分派**（同一个文档的 open/change/close/job 都
;;; 送到同一个 worker），worker 各自维护影子文本，主进程只发增量。
;;;
;;;   poll!   非阻塞抽干 mailbox（+ signal）
;;;   source  返回 signal —— 后端 on-source 注册它，结果到达即唤醒事件循环重绘
;;;
;;; worker 路径用 define-runtime-path 解析（编译后 / 换 CWD 都找得到）。

(provide make-place-runner)

(define-runtime-path worker.rkt "worker.rkt")

(define (make-place-runner [n 2])
  (define mailbox (make-async-channel))
  (define signal (make-async-channel))
  (define workers
    (for/list ([_ (in-range (max 1 n))])
      (define w (dynamic-place worker.rkt 'worker-main))
      (thread (lambda ()
                (with-handlers ([exn? (lambda (e) (void))])
                  (let loop ()
                    (define msg (place-channel-get w))
                    (async-channel-put mailbox msg)
                    (async-channel-put signal 'ready)
                    (loop)))))
      w))
  (define ws (list->vector workers))
  (define (w did) (vector-ref ws (modulo did (vector-length ws))))
  (make-runner
   (lambda (did token text) (place-channel-put (w did) (list 'open did token text)))
   (lambda (did from to edits) (place-channel-put (w did) (list 'change did from to edits)))
   (lambda (did token) (place-channel-put (w did) (list 'drop did token)))
   (lambda (did) (place-channel-put (w did) (list 'close did)))
   (lambda (tag name did token path) (place-channel-put (w did) (list 'job tag name did token path)))
   (lambda ()
     (let loop ([acc '()])
       (define v (async-channel-try-get mailbox))
       (if v
           (loop (cons v acc))
           (begin
             ;; 抽干多余唤醒 token（一次 poll 只留一个 source 就绪即可）
             (let drain () (when (async-channel-try-get signal) (drain)))
             (reverse acc)))))
   (lambda () signal)
   (lambda ()
     (for ([p (in-list workers)])
       (with-handlers ([exn? (lambda (e) (void))])
         (place-channel-put p 'stop))))))

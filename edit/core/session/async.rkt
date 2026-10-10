#lang racket

;;; edit-rebuild/core/session/async.rkt —— 异步结果的版本闸门
;;;
;;; 局部问题：异步算出的结果不能盲写（文档可能已变）。闸门登记
;;;   「请求 id + 版本 token + current? 判据 + on-result」，
;;; 结果回来时只在 current? 仍成立才施加 on-result。
;;;
;;;   session-await   : s id token current? on-result -> s
;;;   session-deliver : s id result -> s
;;;
;;; 传输（sync / place）在 async/runner.rkt，与本层无关。
;;;
;;; async-wake：TUI 事件循环的异步唤醒通道。worker 有结果就往里放 'ready，
;;; tui 用 (on-source async-wake proc) 注册；于是无需轮询。

(require racket/async-channel
         "session.rkt")

(provide session-await session-deliver session-awaiting? async-wake)

(define async-wake (make-async-channel))

(define (session-awaiting? s id) (and (session-await-ref s id) #t))

(define (session-await s id token current? on-result)
  (session-await-put s id (list token current? on-result)))

(define (session-deliver s id result)
  (define e (session-await-ref s id))
  (cond
    [(not e) s]
    [else
     (define token (car e))
     (define cur? (cadr e))
     (define on-result (caddr e))
     (define s1 (session-await-remove s id))
     (if (cur? s1 token) (on-result s1 result) s1)]))

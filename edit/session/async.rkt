#lang racket

;;; edit/session/async.rkt —— 异步结果的版本闸门
;;;
;;; 异步计算（别的线程 / 进程）算出的结果不能盲写：文档可能已经变了。
;;; 闸门：登记「请求 + 版本 token + current? 判据 + on-result」，结果回来时
;;; 只在 current? 仍成立才施加 on-result。
;;;
;;;   session-await   : s id token current? on-result -> s
;;;   session-deliver : s id result -> s          ; 命中且 current? → on-result
;;;
;;; current? : session token -> boolean；edit 里 token 通常就是 document handle
;;; （每次编辑产生新 handle），于是「文档没变才写回」。
;;;
;;; 传输（sync / place、请求合并）由插件用 plugin/runner.rkt 自管；这里只管闸门。

(require "value.rkt")

(provide session-await session-deliver session-awaiting? session-awaiting-any?)

(define (session-awaiting? s id) (hash-has-key? (session-awaiting s) id))
(define (session-awaiting-any? s) (positive? (hash-count (session-awaiting s))))

(define (session-await s id token current? on-result)
  (struct-copy session s
    [awaiting (hash-set (session-awaiting s) id (list token current? on-result))]))

(define (session-deliver s id result)
  (define e (hash-ref (session-awaiting s) id #f))
  (cond
    [(not e) s]
    [else
     (define token (car e))
     (define cur? (cadr e))
     (define on-result (caddr e))
     (define s1 (struct-copy session s [awaiting (hash-remove (session-awaiting s) id)]))
     (if (cur? s1 token) (on-result s1 result) s1)]))

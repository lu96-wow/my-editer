#lang racket

;;; edit3/plugins/async-demo.rkt —— 异步 jobs 示例插件
;;;
;;; 演示 worker 机制：M-o 登记一个 'slow-words job（结果异步回来），完成后由 'job 钩子
;;; 写进 State。service handler 在 worker 线程里跑，是**纯函数**（不碰 State）。
;;; 默认不启用；测试 / 用户显式启用。

(require "../core/extension.rkt")

(provide async-spec)

;; 触发：登记 job（已是 loading 就不重复登记）。
(define (async-load _ctx st _ev _args)
  (cond
    [(feature-ref st 'async-loading #f) (values st '())]
    [else
     (define-values (st* _j) (job-submit st 'slow-words (hash 'n 4) 'async-demo))
     (values (feature-set st* 'async-loading #t) '())]))

;; worker：payload -> result（在 worker 线程，纯）。
(define (slow-words payload)
  (for/list ([i (in-range (hash-ref payload 'n 3))])
    (format "async-item-~a" i)))

;; 结果回注后：'job 钩子按 tag 分派。
(define (async-on-job st args)
  (cond
    [(and (list? args) (= 4 (length args)) (eq? (list-ref args 3) 'async-demo))
     (feature-set (feature-set st 'async-result (list-ref args 2)) 'async-loading #f)]
    [else st]))

(define async-spec
  (make-plugin
   #:name 'async-demo
   #:ops (list (cons 'async-load async-load))
   #:services (list (service 'slow-words slow-words))
   #:key-tables (list '(((key o alt) always (async-load))))
   #:hooks (list (reaction* 'job async-on-job))))

#lang racket

;;; edit4/plugins/async-demo.rkt —— 异步 jobs 演示包（service + job 钩子）
;;;
;;; M-o 登记一个 'slow-words job（结果异步回来），完成后由 'job 钩子写进 store。
;;; service handler 在 worker 线程里跑，是**纯函数**（不碰 World）。
;;; 不默认启用。

(provide async-demo-plugin)

(require "../plugin.rkt"
         "../core/world.rkt" "../core/store.rkt"
         "../core/command.rkt" "../core/job.rkt" "../core/hook.rkt")

(define (loading? w) (store-ref (world-store w) 'async-loading #f))

(define (h-async-load _ctx w _args)
  (cond
    [(loading? w) (cons w '())]                 ; 已在途，不重复登记
    [else
     (define-values (w* _j) (job-submit w 'slow-words (hash 'n 4) 'async-demo))
     (cons (world-set-store w* (store-set (world-store w*) 'async-loading #t)) '())]))

;; worker：payload -> result（纯）。
(define (slow-words payload)
  (for/list ([i (in-range (hash-ref payload 'n 3))]) (format "async-item-~a" i)))

;; 结果回注后：'job 钩子按 tag 分派。
(define (async-on-job w args)
  (if (and (list? args) (= 4 (length args)) (eq? (list-ref args 3) 'async-demo))
      (let* ([s (store-set (world-store w) 'async-result (list-ref args 2))]
             [s (store-set s 'async-loading #f)])
        (world-set-store w s))
      w))

(define async-demo-commands
  (make-command-registry (list (cons 'async-load h-async-load))))

(define async-demo-plugin
  (make-plugin
   #:name 'async-demo
   #:commands async-demo-commands
   #:keymap (list (list '(key o alt) 'always (cmd 'async-load)))
   #:services (list (service 'slow-words slow-words))
   #:hooks (list (reaction* 'job async-on-job))))

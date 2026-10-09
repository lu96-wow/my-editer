#lang racket

;;; edit/test/async-test.rkt —— 异步结果闸门验证（headless）
;;;
;;;   raco test edit/test/async-test.rkt
;;;
;;; 覆盖：runner 提交 → before-render 轮询 → session-deliver 版本闸门；
;;;       命中则施加 on-result，过期（current? #f）则丢弃；sync / place 两种 runner；
;;;       异常变成 (job-result #f msg)，与返回 #f 区分。

(require rackunit
         racket/runtime-path
         "../demo.rkt"
         "../session.rkt"
         "../plugin/runner.rkt")

(define-runtime-path worker-path "async-worker.rkt")

;; 同步 runner：handler 就地把请求变成结果（换 place 时业务不变）
(define r (make-sync-runner (lambda (req) (* 2 req))))

(define delivered (box '()))

;; 注册 before-render 钩子：每帧轮询 runner，把到齐的结果交给闸门
(define base
  (session-add-hook
   (demo-session 80 24)
   (hook 'before-render
         (lambda (s _args)
           (for/fold ([s s]) ([m (in-list (runner-poll! r))])
             (session-deliver s (car m) (cdr m)))))))

;; --- 命中：版本仍当前 → 交付 ---
(define id (runner-submit! r 21))
(define h1 (session-await base id 'token (lambda (s _t) #t)
                          (lambda (s result)
                            (when (job-result-ok? result)
                              (set-box! delivered (cons (job-result-value result) (unbox delivered))))
                            s)))
(define h2 (session-prepare-render h1))
(check-equal? (unbox delivered) '(42))
(check-false (session-awaiting? h2 id))

;; --- 异常：不再被吞成 #f，而是 (job-result #f 消息) ---
(define re (make-sync-runner (lambda (_req) (error 'boom "炸了"))))
(define eid (runner-submit! re 'x))
(define er (let loop ([n 0])
             (define m (runner-poll! re))
             (cond [(pair? m) (cdar m)]
                   [(> n 200) #f]
                   [else (sleep 0.01) (loop (add1 n))])))
(check-pred job-result? er)
(check-false (job-result-ok? er))
(check-true (string? (job-result-value er)))

;; --- 过期：current? 为假 → 丢弃 ---
(define id2 (runner-submit! r 7))
(define k1 (session-await base id2 'token (lambda (s _t) #f)
                          (lambda (s _result) (set-box! delivered 'bad) s)))
(define k2 (session-prepare-render k1))
(check-equal? (unbox delivered) '(42))
(check-false (session-awaiting? k2 id2))

;; --- place runner：真并行（业务 handler 与 sync 完全一样） ---
(define pr (make-place-runner worker-path 'main))
(define pid (runner-submit! pr 5))
(define pres (let loop ([n 0])
               (define m (runner-poll! pr))
               (cond [(pair? m) (cdar m)]
                     [(> n 500) #f]
                     [else (sleep 0.01) (loop (add1 n))])))
(check-pred job-result? pres)
(check-true (job-result-ok? pres))
(check-equal? (job-result-value pres) 10)
(runner-stop! pr)

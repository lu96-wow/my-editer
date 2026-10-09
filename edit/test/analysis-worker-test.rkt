#lang racket

;;; edit/test/analysis-worker-test.rkt —— 分析工具：门面 + place worker（headless）
;;;
;;;   raco test edit/test/analysis-worker-test.rkt

(require rackunit
         racket/runtime-path
         "../plugin/runner.rkt"
         "../plugin/analysis/tools/span.rkt"
         "../plugin/analysis/tools/analyze.rkt")

(define-runtime-path worker-path "../plugin/analysis/tools/worker.rkt")

(define path (string->path "/tmp/analysis-worker-test.rkt"))
(define text "#lang racket\n(define (f x) (+ x 1))\n(f 2)\n")

;;; ---------- 直接调 ----------

(define ar (analyze path text 7))
(check-pred analysis-result? ar)
(check-equal? (analysis-result-version ar) 7)
(check-pred lex-result? (analysis-result-lex ar))
(check-pred expand-result? (analysis-result-expand ar))
(check-true (pair? (lex-result-tokens (analysis-result-lex ar))))

;;; ---------- 经 place 往返 ----------

(define pr (make-place-runner worker-path 'worker-main))
(define pid (runner-submit! pr (list 'analyze (path->string path) text 1)))
(define pres
  (let loop ([n 0])
    (define m (runner-poll! pr))
    (cond [(pair? m) (cdar m)]
          [(> n 1000) #f]
          [else (sleep 0.01) (loop (add1 n))])))
(check-pred job-result? pres)
(check-true (job-result-ok? pres))
(define pr-result (and (job-result-ok? pres) (job-result-value pres)))
(check-pred analysis-result? pr-result)
(check-equal? (expand-result-sem-tokens (analysis-result-expand pr-result))
              (expand-result-sem-tokens (analysis-result-expand ar)))
(check-equal? (lex-result-tokens (analysis-result-lex pr-result))
              (lex-result-tokens (analysis-result-lex ar)))
(runner-stop! pr)

;;; ---------- 坏请求 → job-result 失败（不炸主进程） ----------

(define pr2 (make-place-runner worker-path 'worker-main))
(define _bid (runner-submit! pr2 '(nope)))
(define bres
  (let loop ([n 0])
    (define m (runner-poll! pr2))
    (cond [(pair? m) (cdar m)]
          [(> n 1000) #f]
          [else (sleep 0.01) (loop (add1 n))])))
(check-pred job-result? bres)
(check-false (job-result-ok? bres))
(runner-stop! pr2)

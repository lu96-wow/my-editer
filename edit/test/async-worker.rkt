#lang racket

;;; edit/test/async-worker.rkt —— place worker 入口（测试用）
;;;
;;;   raco test edit/test/async-test.rkt 里用 make-place-runner 起它。
;;; handler 与同步版一致（* 2），证明「换 place 不改业务」。

(require "../plugin/runner.rkt")

(provide main)

(define (main ch)
  (job-worker-main ch (lambda (req) (* 2 req))))

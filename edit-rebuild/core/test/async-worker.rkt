#lang racket

;;; edit-rebuild/core/test/async-worker.rkt —— place worker 入口（测试用）

(require "../async/runner.rkt")

(provide main)

(define (main ch)
  (job-worker-main ch (lambda (req) (* 2 req))))

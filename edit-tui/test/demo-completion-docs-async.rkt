#lang racket

;;; demo completion/docs 的异步路径：
;;;   C-o -> 本地菜单 + completion job + docs job
;;;   worker result -> completion 候选合并 / docs 更新
;;;   过期 request-id 丢弃。

(require rackunit
         racket/async-channel
         "../main.rkt"
         "../demo/completion-docs.rkt")

(define engine demo-engine)
(define state0 demo-state)
(define-values (s1 _panels) (sync-ui/panels! state0 engine))
(define-values (s2 _ovs) (prepare-demo! s1 engine))

;; 打开补全：本地候选先进入菜单，同时产生 completion + docs job。
(define-values (s3 _acts) (step s2 (key-event (key 'o 'ctrl))))
(define open0 (job-pending (app-state-jobs s3)))
(check-true (>= (length open0) 2))

;; 用真实 worker 跑 demo services，按 open-job 数量收紧结果。
(define rt (start-job-runtime demo-services #:workers 1))
(define ev-ch (job-runtime-event-channel rt))

(define (drain state [guard 20])
  (cond
    [(zero? guard) (error 'drain "job drain guard exhausted")]
    [else
     (dispatch-jobs! rt (app-state-jobs state))
     (define pending (job-pending (app-state-jobs state)))
     (cond
       [(null? pending) state]
       [else
        (define ev (async-channel-get ev-ch))
        (check-true (job-result-event? ev))
        (drain (handle-job-result state ev) (sub1 guard))])]))

(define s4 (drain s3))
(stop-job-runtime rt)

(check-equal? (job-pending (app-state-jobs s4)) '())
(check-not-false (hash-ref (app-state-store s4) 'demo/completion #f))

;; completion 结果合并后，候选里仍然有本地 twice；docs 也已由 docs job 更新。
(define-values (s5 panels5) (sync-ui/panels! s4 engine))
(define-values (s6 _ovs6) (prepare-demo! s5 engine))
(check-true (string-contains? (engine-view-text engine 40) "twice"))
(check-true (string-contains? (engine-view-text engine 30) "twice"))

(displayln "edit-tui-rebuild/test/demo-completion-docs-async.rkt: ok")

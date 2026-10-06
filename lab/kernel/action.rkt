#lang racket

;;; lab-rebuild/kernel/action.rkt —— 一次"请求做某事"的意图。
;;;
;;; before-policy 匹配 Action（有来源与时序），after-policy 变换其产出的 Effect。

(provide (struct-out action) make-command-action action-name)

(struct action (source payload) #:transparent)
;; source = (list 'command spec) | (list 'hook name) | (list 'job-result id)
;;        | (list 'resume sid) | 'tick | ...
;; payload : 该来源的上下文（命令用 (list spec event)）

(define (make-command-action spec ev)
  (action (list 'command spec) (list spec ev)))

(define (action-name a)
  (define s (action-source a))
  (and (pair? s)
       (case (car s)
         [(command) (let ([spec (cadr s)]) (if (pair? spec) (car spec) spec))]
         [(hook) (cadr s)]
         [else #f])))

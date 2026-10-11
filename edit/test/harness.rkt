#lang racket

;;; edit-rebuild/test/harness.rkt —— 假宿主：用纯结构驱动骨架（不需要编辑器）
;;;
;;; state = focus / kind / visible / modes / prefix / log
;;; 命令用普通 list（不是 symbol，避免被当成载荷型 spec）。

(require "../core/key.rkt"
         "../core/scope.rkt"
         "../core/route.rkt"
         "../core/effect.rkt"
         "../core/dispatch.rkt")

(provide (all-defined-out)
         (all-from-out "../core/key.rkt"
                       "../core/scope.rkt"
                       "../core/route.rkt"
                       "../core/effect.rkt"
                       "../core/dispatch.rkt"))

(struct state (focus fid kind visible modes prefix log) #:transparent)

;; 假命令（不是 symbol，避免被当成载荷型 spec）。
(struct cmd-save () #:transparent)
(struct cmd-other () #:transparent)
(struct cmd-noop () #:transparent)

(define (state-new [focus 'editor] [kind 'editor]
                   [visible (hash 'docs #t)]
                   [modes (hash)]
                   [prefix #f]
                   [fid #f])
  (state focus fid kind visible modes prefix '()))

;; 日志按发生顺序（内部是逆序累积）。
(define (log-of st) (reverse (state-log st)))

;; pass? : cmd -> boolean（某些命令返回 'pass，用于测 fallthrough）
(define (mk-host [pass? (lambda (_cmd) #f)])
  (host
   (lambda (st) (context (state-focus st) (state-fid st) (state-kind st)
                         (state-visible st) (state-modes st) (state-prefix st)))
   (lambda (st target cmd)
     (cond
       [(pass? cmd) (values st 'pass)]
       [else (values (struct-copy state st [log (cons (list target cmd) (state-log st))]) 'handled)]))
   (lambda (st target) (values (struct-copy state st [focus target]) 'handled))
   (lambda (st name val)
     (values (struct-copy state st [modes (hash-set (state-modes st) name val)]) 'handled))
   (lambda (st p) (values (struct-copy state st [prefix p]) 'handled))
   (lambda (in spec)
     (case spec
       [(text) (list 'ins (input-text in))]
       [else spec]))))

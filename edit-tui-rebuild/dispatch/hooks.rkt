#lang racket

;;; dispatch/hooks.rkt —— 排空信号 → 跑 hook（纯）
;;;
;;; layer  : dispatch
;;; effect : 无（hook 返回 transition，可能有 effect，但这里只折叠不执行）
;;;
;;; 一个批次：
;;;
;;;   state ──(command)──▶ transition
;;;                            │
;;;                            ▼  run-hooks
;;;        取走 state.signals ──▶ 按 point 找 hook（priority 降序）
;;;                            │      每个 hook : state engine-view args -> transition
;;;                            ▼
;;;                      新 effect 追加到尾部；hook 又可 emit
;;;                            │
;;;                            └──▶ 下一轮（直到队列空 / 达到轮数上限）
;;;
;;; 为什么要“多轮”：上色 hook 发 effect 后可能需要再刷新（暂定留出能力）；
;;; 正常情况下 1 轮就结束。轮数上限是防止 hook 互相触发造成死循环。
;;;
;;; 顺序约定：
;;;   · 同一个 point 内：priority 大者先跑；同 priority 保持注册顺序（稳定排序）；
;;;   · effect 追加在已有 effect 之后，所以“命令先写文本、hook 再上色”成立。

(provide run-hooks)

(require racket/list
         "../base/signal.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../effects/engine.rkt"
         "../env/environment.rkt"
         "../env/hook.rkt")

;; 一轮里最多跑多少批信号（防止 hook 自激）。
(define max-rounds 16)

;; t0 的 state / effects 会被保留，hook 的 effect 追加在后面。
(define (run-hooks env engine t0)
  (let loop ([state (transition-state t0)] [effects (transition-effects t0)] [round 0])
    (define-values (state* sigs) (state-drain-signals state))
    (cond
      [(null? sigs) (transition state* effects)]
      [(>= round max-rounds)
       ;; 放弃剩余信号：宁可丢一次刷新，也不要卡死。
       (transition state* effects)]
      [else
       (define t (for/fold ([t (transition state* '())]) ([sig (in-list sigs)])
                   (run-point env engine t (signal-point sig) (signal-args sig))))
       (loop (transition-state t)
             (append effects (transition-effects t))
             (add1 round))])))

;; 该 point 的所有 hook（priority 降序，稳定）。
(define (point-hooks env point)
  (sort (for/list ([h (in-list (environment-hooks env))]
                   #:when (eq? (hook-point h) point))
          h)
        > #:key hook-priority))

(define (run-point env engine t point args)
  (for/fold ([t t]) ([h (in-list (point-hooks env point))])
    (cond
      [(not ((hook-when h) (transition-state t) engine args)) t]
      [else
       (transition-bind
        t
        (λ (s)
          (define r ((hook-proc h) s engine args))
          (unless (transition? r)
            (error 'run-hooks "hook ~a 的 proc 没有返回 transition：~a" point r))
          r))])))

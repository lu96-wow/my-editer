#lang racket

;;; edit4/core/hook.rkt —— 生命周期钩子（对齐 edit3 reaction/emit）
;;;
;;; reaction : 事件点 + 谓词 when + 优先级 + proc。
;;;   point    : 事件 tag（见 10-plugins.md §4）
;;;   when     : (World -> boolean)          只在该状态下跑（默认总是）
;;;   priority : 大者先
;;;   proc     : (World args -> World)       纯状态转移；args 是事件相关数据
;;;
;;; 命令用 core 的 `emit!` 把信号追加到 World.signals；runtime 调 `run-hooks` 排空：
;;; 反复取信号、按 priority 降序跑匹配的 reaction，直到没有新信号（钩子可再 emit）。

(provide (struct-out reaction) reaction* run-hooks)

(require "world.rkt" racket/list)

(struct reaction (point when priority proc) #:transparent)

(define (reaction* point proc #:when [when (lambda (w) #t)] #:priority [priority 0])
  (reaction point when priority proc))

;; 跑该事件点的所有 reaction（按 priority 降序；when 不满足则跳过）。
(define (run-point hooks w point args)
  (define rs (sort (for/list ([r (in-list hooks)] #:when (eq? point (reaction-point r))) r)
                   > #:key reaction-priority))
  (for/fold ([ww w]) ([r (in-list rs)])
    (if ((reaction-when r) ww) ((reaction-proc r) ww args) ww)))

;; 排空 World.signals：先清空再跑，钩子新 emit 的进下一轮。
(define (run-hooks hooks w)
  (let loop ([w w])
    (define pending (world-signals w))
    (cond
      [(null? pending) w]
      [else
       (define w0 (world-set-signals w '()))
       (define w1 (for/fold ([ww w0]) ([sig (in-list pending)])
                    (run-point hooks ww (car sig) (cdr sig))))
       (loop w1)])))

#lang racket

;;; lab-rebuild/kernel/command.rkt —— 命令调用。
;;;
;;; 命令是 registry 里 kind='command 的贡献；value : (Ctx ev . args) -> (listof effect)。
;;; spec = name | (name . args)。
;;; 三根柱子之一「命令」：一切输入最终解析成一个 command spec，再统一调用。

(require "registry.rkt" "runtime.rkt")

(provide invoke-command)

(define (invoke-command ctx spec ev)
  (define name (if (pair? spec) (car spec) spec))
  (define args (if (pair? spec) (cdr spec) '()))
  (define c (reg-ref (runtime-registry (ctx-runtime ctx)) 'command name))
  (unless c (error 'invoke-command "未知命令: ~a" name))
  (apply (contrib-value c) ctx ev args))

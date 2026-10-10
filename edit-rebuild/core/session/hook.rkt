#lang racket

;;; edit-rebuild/core/session/hook.rkt —— 生命周期通知（点 + 处理器）
;;;
;;; 局部问题：一个「通知点」上的处理器。point 是符号，proc 是
;;;   session (listof any/c) -> session
;;; 发通知时按注册顺序依次跑；返回值串接（处理器可以改会话）。
;;;
;;; 注册（session-add-hook）与派发都在这里（hook 值 + 注册 + 运行）。

(require "session.rkt")

(provide (struct-out hook) session-add-hook session-run-hooks)

(struct hook (point proc) #:transparent)
;; point : symbol
;; proc  : session (listof any/c) -> session

(define (session-add-hook s h)
  (struct-copy session s [hooks (cons h (session-hooks s))]))

(define (session-run-hooks s point args)
  (for/fold ([s s]) ([h (in-list (session-hooks s))] #:when (eq? point (hook-point h)))
    ((hook-proc h) s args)))

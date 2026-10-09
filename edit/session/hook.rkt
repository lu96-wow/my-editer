#lang racket

;;; edit/session/hook.rkt —— 生命周期通知（点 + 处理器）
;;;
;;; hook = 一个「通知点」上的处理器：point 是符号，proc 是
;;;   session (listof any/c) -> session
;;; 发通知时按注册顺序依次跑；返回值串接（hooks 可以改会话）。
;;;
;;; 目前已接入的通知点：
;;;   'after-edit    改文本的原语完成后，args = (vid changes)
;;;   'after-insert  仅「直接编辑」（打字 / 删除 / 粘贴 / 剪切）完成后，args = (vid changes)
;;;   'after-nav     光标导航 / 鼠标定位后，args = (vid)
;;;   'focus-changed 焦点改变后，args = (vid | #f)
;;;   'document-closed 关文档后，args = (did)
;;; 新点由「发通知的一方」决定（见 session/edit.rkt、session/focus.rkt）。

(require "value.rkt")

(provide (struct-out hook) session-add-hook session-run-hooks)

(struct hook (point proc) #:transparent)
;; point : symbol
;; proc  : session (listof any/c) -> session

(define (session-add-hook s h)
  (struct-copy session s [hooks (cons h (session-hooks s))]))

(define (session-run-hooks s point args)
  (for/fold ([s s]) ([h (in-list (session-hooks s))] #:when (eq? point (hook-point h)))
    ((hook-proc h) s args)))

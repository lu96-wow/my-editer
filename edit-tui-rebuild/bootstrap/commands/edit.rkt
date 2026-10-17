#lang racket

;;; layer  : bootstrap/commands
;;; effect : 只发 engine effect（导航 / 编辑 / undo / redo）；quit 只改 State
;;;
;;; 编辑类命令 = “拿 subject view 发一个 engine effect”。
;;; 没有 view 时只写消息，不静默失败。

(provide nav-command
         insert-command
         edit-command
         undo-command
         redo-command
         quit-command)

(require "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../model/state.rkt"
         "../../model/chrome.rkt"
         "../../env/command.rkt"
         "../../dispatch/context.rkt"
         "util.rkt")

;;; ════════════════ 基础命令 ════════════════

(define (nav-command dir)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (nav-effect vid dir)))
             (message ctx "nav: no view")))))

(define (insert-command text)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (insert-text-effect vid text)))
             (message ctx "insert: no view")))))

(define (edit-command op)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid
             (transition (ctx-state ctx) (list (edit-effect vid op)))
             (message ctx "edit: no view")))))

(define (undo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (undo-effect vid)))
             (message ctx "undo: no view")))))

(define (redo-command)
  (cmd (λ (ctx)
         (define vid (view-subject ctx))
         (if vid (transition (ctx-state ctx) (list (redo-effect vid)))
             (message ctx "redo: no view")))))

(define (quit-command)
  (cmd (λ (ctx) (transition-pure (state-mark-quit (ctx-state ctx))))))

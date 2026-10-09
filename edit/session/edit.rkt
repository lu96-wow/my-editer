#lang racket

;;; edit/session/edit.rkt —— 操作原语（文本编辑 / 导航 / 选区 / 剪贴板）
;;;
;;; 命令层需要的那几个原语：焦点移动 / 滚动 / 光标导航 / 选区 / 剪贴板 / 编辑 / 撤销。
;;; 都走 core.rkt 的内核适配，不直接碰 core/editor。
;;; 会改文本的原语在完成后发 'after-edit 通知（vid），供补全等 hook 用。
;;; 会话级纯变换（resize / quit）与结构手术见 value.rkt / structure.rkt。

(require "value.rkt"
         "core.rkt"
         "focus.rkt"
         "hook.rkt"
         "../core/focus.rkt")

(provide
 session-focus-move session-scroll session-nav
 session-select-all session-copy session-cut session-paste
 session-insert session-delete session-backspace
 session-undo session-redo)

(define (with-focus-vid s proc)
  (define vid (session-focus-vid s))
  (if vid (proc s vid) s))

;; 编辑类原语：proc 做完后发 'after-edit 通知（返回值参与串接）。
(define (with-edit s proc)
  (with-focus-vid s (lambda (s vid) (session-run-hooks (proc s vid) 'after-edit (list vid)))))

(define (session-focus-move s dir)
  (session-set-focus s (focus-move (session-views s) (session-focus s) dir)))

(define (session-scroll s n)
  (sync-layout! s)
  (with-focus-vid s (lambda (s vid) (session-ed-scroll! s vid n))))

(define (session-nav s dir extend?)
  (sync-layout! s)
  (with-focus-vid s (lambda (s vid) (session-ed-nav! s vid dir extend?))))

;; 选区 / 剪贴板（转发 core）
(define (session-select-all s)
  (sync-layout! s)
  (with-focus-vid s (lambda (s vid) (session-ed-select-all! s vid))))
(define (session-copy s)
  (with-focus-vid s (lambda (s vid) (session-ed-copy! s vid))))
(define (session-cut s)
  (sync-layout! s)
  (with-edit s (lambda (s vid) (session-ed-cut! s vid))))
(define (session-paste s)
  (sync-layout! s)
  (with-edit s (lambda (s vid) (session-ed-paste! s vid))))

(define (session-insert s text)
  (sync-layout! s)
  (with-edit s (lambda (s vid) (session-ed-insert! s vid text))))
(define (session-delete s)
  (sync-layout! s)
  (with-edit s (lambda (s vid) (session-ed-delete! s vid))))
(define (session-backspace s)
  (sync-layout! s)
  (with-edit s (lambda (s vid) (session-ed-backspace! s vid))))
(define (session-undo s)
  (sync-layout! s)
  (with-edit s (lambda (s vid) (session-ed-undo! s vid))))
(define (session-redo s)
  (sync-layout! s)
  (with-edit s (lambda (s vid) (session-ed-redo! s vid))))

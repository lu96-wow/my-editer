#lang racket

;;; edit-rebuild/core/session/edit.rkt —— 操作原语（编辑 / 导航 / 选区 / 剪贴板）
;;;
;;; 局部问题：命令层需要的那几个会话语义操作，都走 adapter 的内核适配。
;;; 会改文本的原语完成后发
;;;   'after-edit   (vid changes)   所有改动
;;;   'after-insert (vid changes)   仅「直接编辑」（打字 / 删除 / 粘贴 / 剪切）
;;; 导航类原语发 'after-nav (vid)。供增量插件 / 补全等 hook 用。

(require "session.rkt"
         "adapter.rkt"
         "focus.rkt"
         "hook.rkt"
         "../focus.rkt")

(provide
 session-focus-move session-scroll session-nav
 session-select-all session-copy session-cut session-paste
 session-insert session-delete session-backspace
 session-undo session-redo)

(define (with-focus-vid s proc)
  (define vid (session-focus-vid s))
  (if vid (proc s vid) s))

(define (with-nav s proc)
  (with-focus-vid s
    (lambda (s vid) (session-run-hooks (proc s vid) 'after-nav (list vid)))))

(define (with-edit s proc)
  (with-focus-vid s
    (lambda (s vid)
      (define-values (s* changes) (proc s vid))
      (cond
        [(null? changes) s*]
        [else
         (session-run-hooks
          (session-run-hooks s* 'after-edit (list vid changes))
          'after-insert (list vid changes))]))))

(define (session-focus-move s dir)
  (session-set-focus s (focus-move (session-views s) (session-focus s) dir)))

(define (session-scroll s n)
  (sync-layout! s)
  (with-focus-vid s (lambda (s vid) (session-ed-scroll! s vid n))))

(define (session-nav s dir extend?)
  (sync-layout! s)
  (with-nav s (lambda (s vid) (session-ed-nav! s vid dir extend?))))

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

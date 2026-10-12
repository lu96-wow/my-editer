#lang racket

;;; edit4/content/commands.rkt —— 内容（编辑 / 导航）命令 + 键表
;;;
;;; 命令只调 content/engine 的原语，作用于「焦点窗口显示的 vid」。
;;; 编辑是引擎的原地写；World 值不变（脏由 handle 身份推出）。

(provide content-commands content-keymap)

(require racket/match
         "../core/event.rkt" "../core/world.rkt" "../core/command.rkt" "../core/keymap.rkt"
         "content.rkt" "engine.rkt")

(define (focused-vid world)
  (define c (world-content world))
  (and c (content-vid-of c (world-focus world))))

(define (edit-via world f)
  (define v (focused-vid world))
  (cond
    [(not v) #f]
    [else (f (content-ed (world-content world)) v) (cons world '())]))

;;; ---------- 编辑 ----------

(define (h-insert-text ctx world args)
  (edit-via world (lambda (ed v) (insert! ed v (car args)))))

(define (h-insert-event ctx world args)
  (edit-via world (lambda (ed v) (insert! ed v (text-event-text (ctx-event ctx))))))

(define (h-delete-back ctx world args) (edit-via world (lambda (ed v) (backspace! ed v))))
(define (h-delete ctx world args) (edit-via world (lambda (ed v) (delete! ed v))))
(define (h-select-all ctx world args) (edit-via world (lambda (ed v) (select-all! ed v))))
(define (h-copy ctx world args) (edit-via world (lambda (ed v) (copy! ed v))))
(define (h-cut ctx world args) (edit-via world (lambda (ed v) (cut! ed v))))
(define (h-paste ctx world args) (edit-via world (lambda (ed v) (paste! ed v))))
(define (h-undo ctx world args) (edit-via world (lambda (ed v) (undo! ed v))))
(define (h-redo ctx world args) (edit-via world (lambda (ed v) (redo! ed v))))

(define (h-nav ctx world args)
  (define dir (car args))
  (define extend? (and (pair? (cdr args)) (cadr args)))
  (edit-via world (lambda (ed v) (nav! ed v dir extend?))))

;;; ---------- 注册表 ----------

(define content-commands
  (make-command-registry
   (list (cons 'insert-text h-insert-text)
         (cons 'insert-event-text h-insert-event)
         (cons 'delete-back h-delete-back)
         (cons 'delete h-delete)
         (cons 'select-all h-select-all)
         (cons 'copy h-copy)
         (cons 'cut h-cut)
         (cons 'paste h-paste)
         (cons 'undo h-undo)
         (cons 'redo h-redo)
         (cons 'nav h-nav))))

;;; ---------- 键表（编辑作用域；先用 always，'editor scope 后补） ----------

(define content-keymap
  (list (list '(text) 'always (cmd 'insert-event-text))
        (list '(key backspace) 'always (cmd 'delete-back))
        (list '(key delete) 'always (cmd 'delete))
        (list '(key left) 'always (cmd 'nav 'left))
        (list '(key right) 'always (cmd 'nav 'right))
        (list '(key up) 'always (cmd 'nav 'up))
        (list '(key down) 'always (cmd 'nav 'down))
        (list '(key home) 'always (cmd 'nav 'home))
        (list '(key end) 'always (cmd 'nav 'end))
        (list '(key a ctrl) 'always (cmd 'select-all))
        (list '(key z ctrl) 'always (cmd 'undo))
        (list '(key y ctrl) 'always (cmd 'redo))))

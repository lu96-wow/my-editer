#lang racket

;;; edit4/content/edit.rkt —— 编辑 / 导航命令
;;;
;;; 命令只调 content/adapter 的原语，作用于「焦点窗口显示的 vid」。
;;; 编辑是引擎的原地写；World 值不变（脏由 handle 身份推出）。

(provide edit-commands)

(require
         "../core/event.rkt" "../core/world.rkt" "../core/command.rkt"
         "model.rkt" "adapter.rkt")

(define (focused-vid world)
  (define c (world-content world))
  (and c (content-vid-of c (world-focus world))))

;; 在焦点 vid 上做一次编辑/导航，并 emit 对应钩子点。
;; point : 钩子点；extra : v -> args（该点的参数）。
(define (edit-via world point extra f)
  (define v (focused-vid world))
  (cond
    [(not v) #f]
    [else (f (content-ed (world-content world)) v)
          (cons (emit! world point (extra v)) '())]))

(define (after-edit-args v) (list v))

(define (h-insert-text ctx world args)
  (define text (car args))
  (edit-via world 'after-insert (lambda (v) (list v text))
            (lambda (ed v) (insert! ed v text))))
(define (h-insert-event ctx world args)
  (define text (text-event-text (ctx-event ctx)))
  (edit-via world 'after-insert (lambda (v) (list v text))
            (lambda (ed v) (insert! ed v text))))
(define (h-delete-back ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (backspace! ed v))))
(define (h-delete ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (delete! ed v))))
(define (h-select-all ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (select-all! ed v))))
(define (h-copy ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (copy! ed v))))
(define (h-cut ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (cut! ed v))))
(define (h-paste ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (paste! ed v))))
(define (h-undo ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (undo! ed v))))
(define (h-redo ctx world args) (edit-via world 'after-edit after-edit-args (lambda (ed v) (redo! ed v))))

(define (h-nav ctx world args)
  (define dir (car args))
  (define extend? (and (pair? (cdr args)) (cadr args)))
  (edit-via world 'after-nav after-edit-args (lambda (ed v) (nav! ed v dir extend?))))

(define edit-commands
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

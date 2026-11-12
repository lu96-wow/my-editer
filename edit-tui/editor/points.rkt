#lang racket

;;; edit-tui-rebuild/editor/points.rkt —— 显式插入点表
;;;
;;; 只定义 point 名 / 允许的 phase / context 类别；不依赖 hooks / layout / state。
;;; make-hook 用它校验 operation / phase；registry 仍由 hooks.rkt 维护。

(provide (struct-out point-spec)
         known-point?
         point-spec-of
         point-phases
         point-context
         point-names)

(struct point-spec
  (name
   kind       ; 'hook | 'contribution
   phases
   context)  ; 'edit | 'change | 'layout | 'frame | 'timer | 'job | 'command
  #:transparent)

(define table
  (hash
   'insert       (point-spec 'insert 'hook '(validate transform derive observe) 'edit)
   'delete       (point-spec 'delete 'hook '(validate transform derive observe) 'edit)
   'changes      (point-spec 'changes 'hook '(derive observe) 'change)
   'layout-split (point-spec 'layout-split 'hook '(validate transform derive observe) 'layout)
   'layout-close (point-spec 'layout-close 'hook '(validate transform derive observe) 'layout)
   'layout-focus (point-spec 'layout-focus 'hook '(validate transform derive observe) 'layout)
   'frame/sync   (point-spec 'frame/sync 'contribution '(sync) 'frame)
   'frame/overlay (point-spec 'frame/overlay 'contribution '(overlay) 'frame)
   'timer        (point-spec 'timer 'contribution '(timer) 'timer)
   'job-service  (point-spec 'job-service 'contribution '(service) 'job)
   'job-result   (point-spec 'job-result 'contribution '(result) 'job)
   'command      (point-spec 'command 'contribution '(command) 'command)
   'key-owner    (point-spec 'key-owner 'contribution '(owner) 'command)))

(define (known-point? name)
  (hash-has-key? table name))

(define (point-spec-of name)
  (hash-ref table name #f))

(define (point-phases name)
  (define p (point-spec-of name))
  (and p (point-spec-phases p)))

(define (point-context name)
  (define p (point-spec-of name))
  (and p (point-spec-context p)))

(define (point-names)
  (hash-keys table))

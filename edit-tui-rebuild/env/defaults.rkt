#lang racket

;;; env/defaults.rkt —— 内置 role / mode 默认值（纯值）
;;;
;;; 这里只放“没有命令也能成立”的默认：role 行为、mode 的 fallback。
;;; 默认键表 / 命令在 bootstrap/defaults（需要 ops，放后面块）。

(provide default-roles
         default-modes
         default-environment)

(require "role.rkt"
         "mode.rkt"
         "environment.rkt")

(define default-roles
  (hash 'editor (make-role #:splittable? #t #:close 'keep-last #:focusable? #t)
        'panel  (make-role #:splittable? #f #:close 'hide      #:focusable? #f)
        'slot   (make-role #:splittable? #f #:close 'ignore    #:focusable? #f)
        'tool   (make-role #:splittable? #t #:close 'delete    #:focusable? #t)
        'resource (make-role #:splittable? #f #:close 'ignore  #:focusable? #t)))

(define default-modes
  (hash 'text   (make-mode #:fallback 'insert)
        'status (make-mode #:fallback 'ignore)
        'input  (make-mode #:fallback 'insert)))

(define default-environment
  (make-environment #:roles default-roles
                    #:modes default-modes))

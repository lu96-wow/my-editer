#lang racket

;;; lab-rebuild/config/packages.rkt —— 功能包目录（纯数据）。

(require "../builtin/edit.rkt"
         "../builtin/indent.rkt"
         "../builtin/autopair.rkt"
         "../builtin/mouse.rkt"
         "../builtin/buffers.rkt"
         "../builtin/prefix.rkt"
         "../builtin/highlight.rkt"
         "../builtin/complete.rkt"
         "../builtin/docs.rkt"
         "../builtin/translate.rkt"
         "../builtin/document.rkt"
         "../builtin/prompt.rkt"
         "../builtin/status.rkt"
         "../builtin/tree.rkt"
         "../builtin/policy.rkt")

(provide package-catalog)

(define package-catalog
  (list (cons 'edit     register-edit!)
        (cons 'indent   register-indent!)
        (cons 'autopair register-autopair!)
        (cons 'mouse    register-mouse!)
        (cons 'buffers  register-buffers!)
        (cons 'prefix   register-prefix!)
        (cons 'highlight register-highlight!)
        (cons 'complete register-complete!)
        (cons 'docs     register-docs!)
        (cons 'translate register-translate!)
        (cons 'document register-document!)
        (cons 'prompt   register-prompt!)
        (cons 'status   register-status!)
        (cons 'tree     register-tree!)
        (cons 'policy   register-policies!)))

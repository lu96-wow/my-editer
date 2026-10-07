#lang racket

;;; lab-rebuild/config/packages.rkt —— 功能包目录（纯数据）。
;;;
;;; 每条 = (name . register-proc)。app-init 按顺序折叠进 registry：
;;; 后面的同名命令 upsert 前面的（如 indent 覆盖 newline）。
;;; 增删功能只改这张表，app 不动。

(require "../builtin/edit.rkt"
         "../builtin/status.rkt"
         "../builtin/prompt.rkt"
         "../builtin/prefix.rkt"
         "../builtin/panels.rkt"
         "../builtin/tree.rkt"
         "../builtin/mouse.rkt"
         "../builtin/autopair.rkt"
         "../builtin/indent.rkt"
         "../builtin/complete.rkt"
         "../builtin/docs.rkt"
         "../builtin/highlight.rkt"
         "../builtin/translate.rkt"
         "../builtin/policy.rkt")

(provide package-catalog)

(define package-catalog
  (list (cons 'edit        register-edit!)
        (cons 'status      register-status!)
        (cons 'mouse       register-mouse!)
        (cons 'prefix      register-prefix!)
        (cons 'panels      register-panels!)
        (cons 'tree        register-tree!)
        (cons 'prompt      register-prompt!)
        (cons 'autopair    register-autopair!)
        (cons 'indent      register-indent!)      ; 覆盖 newline
        (cons 'complete    register-complete!)
        (cons 'docs        register-docs!)
        (cons 'highlight   register-highlight!)
        (cons 'translate   register-translate!)
        (cons 'policy      register-policies!)))

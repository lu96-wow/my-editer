#lang racket

;;; edit4/plugin.rkt —— 装配：插件就是 environment -> environment 的 lambda
;;;
;;; 不再有「带槽位的 plugin 记录」再解释。一个插件就是一个装配变换（lambda），
;;; 组合 = fold（install）。「加功能」= 写一个 lambda，或用下面的 add-* 组合出来。
;;; core 不认识插件；插件只依赖 Environment（数据）与各注册表的代数。

(provide install
         add-commands add-scopes add-keymap add-panels add-decor)

(require "env.rkt"
         "core/command.rkt" "core/scope.rkt" "core/keymap.rkt")

;; install : environment (listof (environment -> environment)) -> environment
(define (install env plugins)
  (for/fold ([e env]) ([p (in-list plugins)]) (p e)))

;;; ---------- 常用装配子（都是 lambda） ----------

(define (add-commands reg)
  (lambda (e) (struct-copy environment e
                           [commands (command-registry-merge (environment-commands e) reg)])))

(define (add-scopes reg)
  (lambda (e) (struct-copy environment e
                           [scopes (scope-registry-merge (environment-scopes e) reg)])))

(define (add-keymap km)
  (lambda (e) (struct-copy environment e
                           [keymap (compose-keymaps (list (environment-keymap e) km))])))

(define (add-panels ps)
  (lambda (e) (struct-copy environment e [panels (append (environment-panels e) ps)])))

(define (add-decor ds)
  (lambda (e) (struct-copy environment e [decor (append (environment-decor e) ds)])))

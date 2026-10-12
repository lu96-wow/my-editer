#lang racket

;;; edit4/plugin.rkt —— 插件契约（数据包）+ 装配 fold（L5）
;;;
;;; plugin 只是数据：命令 / 作用域 / 键表 / 面板 / 装饰。
;;; install 是唯一装配动作：把插件 fold 到 Environment 上（后装覆盖同 slot / 追加列表）。
;;; 于是「加功能」= 新增一个 plugin 值，而不是改核心。
;;;
;;; 命令/作用域/键表需要按名覆盖，所以是 registry/keymap；面板与装饰本身就是函数列表，
;;; 直接 append。这里不引入额外的装配子（lambda 组合子），保持概念最少。

(provide (struct-out plugin) make-plugin empty-plugin install)

(require "env.rkt"
         "core/command.rkt" "core/scope.rkt" "core/keymap.rkt")

(struct plugin (commands scopes keymap panels decor) #:transparent)
;; commands : command-registry
;; scopes   : scope-registry
;; keymap   : (listof entry)
;; panels   : (listof (World -> projection))
;; decor    : (listof (path text cursor -> (listof (vectorof face))))

(define (make-plugin #:commands [c (make-command-registry)]
                     #:scopes   [s (make-scope-registry)]
                     #:keymap   [k '()]
                     #:panels   [p '()]
                     #:decor    [d '()])
  (plugin c s k p d))

(define empty-plugin (make-plugin))

;; install : Environment (listof plugin) -> Environment
(define (install env plugins)
  (for/fold ([e env]) ([p (in-list plugins)])
    (environment
     (command-registry-merge (environment-commands e) (plugin-commands p))
     (scope-registry-merge   (environment-scopes e)   (plugin-scopes p))
     (compose-keymaps (list (environment-keymap e) (plugin-keymap p)))
     (append (environment-panels e) (plugin-panels p))
     (append (environment-decor e)  (plugin-decor p)))))

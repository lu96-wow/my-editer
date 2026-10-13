#lang racket

;;; edit4/app.rkt —— 内置插件装配（→ Environment）
;;;
;;; 组装根：基础命令/内容/面板 + catalog 里启用的插件，fold 成一次运行的 Environment。
;;; 最后把合并后的 prompt-kinds 重注册进 prompt-submit（闭包捕获注册表）。
;;; core 不 require 插件；插件实现只 require 契约（extension 白名单在 plugin.rkt）。

(provide app-environment)

(require "env.rkt" "plugin.rkt"
         "core/base.rkt" "core/command.rkt"
         "content/commands.rkt" "content/scopes.rkt" "content/prompt.rkt"
         "view/panel.rkt" "view/decor.rkt"
         "plugins/catalog.rkt" "config/plugins.rkt")

(define (app-environment)
  (define base-env
    (install (base-environment)
             (list
              ;; 基础命令 / 作用域：先注册（插件可按名覆盖同一条）
              (make-plugin #:name 'base #:commands base-commands #:scopes base-scopes)
              ;; 内容：编辑 / 文件 / 文件树 / 输入行 + 内容键表与作用域
              (make-plugin #:name 'content #:commands content-commands #:scopes content-scopes #:keymap content-keymap)
              ;; 面板：状态栏 + 文件树 + 文档管理 + 日志
              (make-plugin #:name 'panels #:panels base-panels)
              ;; 基础键表（plugins 之后装 → 插件键表覆盖同 slot）
              (make-plugin #:name 'base-keys #:keymap base-keymap))))
  (define env (install base-env (plugins-by-names enabled-plugins)))
  ;; prompt kind 注册表在插件装配后才齐：重注册 prompt-submit 命令闭包捕获它。
  (struct-copy environment env
               [commands (command-register (environment-commands env) 'prompt-submit
                                           (make-prompt-submit (environment-prompt-kinds env)))]))

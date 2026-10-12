#lang racket

;;; edit4/app.rkt —— 内置插件装配（→ Environment）
;;;
;;; 这里是「组装根」：把内置插件 fold 成一次运行的 Environment。
;;; 一个 plugin 一行，读起来就是这份配置清单。core 不 require 插件。
;;; 初始 World 的构造在 boot.rkt。

(provide app-environment)

(require "env.rkt" "plugin.rkt"
         "core/base.rkt"
         "content/commands.rkt" "content/scopes.rkt"
         "view/panel.rkt"
         "decor/syntax.rkt" "decor/words.rkt")

(define (app-environment)
  (install (base-environment)
           (list
            ;; 基础：窗口 / 焦点 / 指针 + 默认键表
            (make-plugin #:commands base-commands #:scopes base-scopes #:keymap base-keymap)
            ;; 内容：编辑 / 文件 / 文件树 + 内容键表与作用域
            (make-plugin #:commands content-commands #:scopes content-scopes #:keymap content-keymap)
            ;; 面板：状态栏 + 文件树
            (make-plugin #:panels base-panels)
            ;; 装饰：语法 / 当前词（普通 lambda，列表里一放即可）
            (make-plugin #:decor (list syntax-decor words-decor)))))

#lang racket

;;; edit4/app.rkt —— 内置插件装配（→ Environment）
;;;
;;; 这里是「组装根」：把内置插件（都是 environment -> environment 的 lambda）fold 成
;;; 一次运行的 Environment。加功能 = 往列表里加一个 lambda；core 不 require 插件。
;;; 初始 World 的构造在 boot.rkt。

(provide app-environment)

(require "env.rkt" "plugin.rkt"
         "core/base.rkt"
         "content/commands.rkt"
         "view/panel.rkt"
         "decor/syntax.rkt" "decor/words.rkt")

(define (app-environment)
  (install (base-environment)
           (list
            ;; 基础：窗口 / 焦点 / 指针 + 默认键表
            (add-commands base-commands) (add-scopes base-scopes) (add-keymap base-keymap)
            ;; 内容：编辑 / 文件 + 内容键表
            (add-commands content-commands) (add-keymap content-keymap)
            ;; 面板：状态栏 + 文件树
            (add-panels base-panels)
            ;; 装饰：语法 / 当前词（普通 lambda，列表里一放即可）
            (add-decor (list syntax-decor words-decor)))))

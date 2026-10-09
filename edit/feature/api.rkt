#lang racket

;;; edit/feature/api.rkt —— 特性门面
;;;
;;; feature 只 require 这一个模块，拿到：
;;;   · session 原语 / 查询（session-*）
;;;   · 基础命令（cmd-*）+ step
;;;   · 绑定键构造（key/mouse/text-binding/text-spec）
;;;   · 键表（kbd/keymap-*）
;;;   · 面板文档构造（panel-doc）
;;; 不必穿透 command / core 多层。

(require "../command/session.rkt"
         "../command/command.rkt"
         "../command/key.rkt"
         "../core/keymap.rkt")

(provide (all-from-out "../command/session.rkt"
                       "../command/command.rkt"
                       "../command/key.rkt"
                       "../core/keymap.rkt"))

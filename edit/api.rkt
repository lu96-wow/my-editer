#lang racket

;;; edit/api.rkt —— 统一出口（facade）
;;;
;;; 命令层 / 后端 / 特性只 require 这一个模块，不直接 require 内部实现。
;;; 内部换实现（view / layout / focus / docs / keymap …）不动调用点。

(require "core/area.rkt"
         "core/layout.rkt"
         "core/focus.rkt"
         "core/keymap.rkt"
         "command/binding.rkt"
         "command/command.rkt"
         "command/keys.rkt")

(provide (all-from-out "core/area.rkt"
                       "core/layout.rkt"
                       "core/focus.rkt"
                       "core/keymap.rkt"
                       "command/binding.rkt"
                       "command/command.rkt"
                       "command/keys.rkt"))

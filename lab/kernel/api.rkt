#lang racket

;;; lab-rebuild/kernel/api.rkt —— kernel 公开门面。
;;;
;;; 功能包只 require 本模块（+ 自己的 lang/ 等），不逐个 require kernel 内部模块。
;;; 这也是 lab 与 kernel 的稳定接口面。

(require "editor-api.rkt"
         "registry.rkt" "effect.rkt" "policy.rkt" "layer.rkt" "table.rkt"
         "binding.rkt" "hooks.rkt" "overlay.rkt" "runner.rkt" "layout.rkt"
         "session.rkt" "runtime.rkt" "frame.rkt" "focus.rkt" "paths.rkt"
         "face.rkt" "theme.rkt" "wrap.rkt" "panel.rkt" "pipeline.rkt")

(provide (all-from-out "editor-api.rkt"
                       "registry.rkt" "effect.rkt" "policy.rkt" "layer.rkt" "table.rkt"
                       "binding.rkt" "hooks.rkt" "overlay.rkt" "runner.rkt" "layout.rkt"
                       "session.rkt" "runtime.rkt" "frame.rkt" "focus.rkt" "paths.rkt"
                       "face.rkt" "theme.rkt" "wrap.rkt" "panel.rkt" "pipeline.rkt"))

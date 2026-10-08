#lang racket

;;; lab-rebuild/kernel/api.rkt —— kernel 公开门面。
;;;
;;; 功能包只 require 本模块（+ 自己的 lang/ 等），不逐个 require kernel 内部模块。

(require "editor-api.rkt"
         "registry.rkt" "effect.rkt" "focus.rkt" "session.rkt" "runtime.rkt"
         "frame.rkt" "dock.rkt" "workspace.rkt" "geometry.rkt" "documents.rkt" "paths.rkt"
         "table.rkt" "binding.rkt" "command.rkt" "hooks.rkt" "layer.rkt"
         "action.rkt" "policy.rkt" "face.rkt" "theme.rkt" "wrap.rkt" "overlay.rkt"
         "runner.rkt" "pipeline.rkt" "render.rkt")

(provide (all-from-out "editor-api.rkt"
                       "registry.rkt" "effect.rkt" "focus.rkt" "session.rkt" "runtime.rkt"
                       "frame.rkt" "dock.rkt" "workspace.rkt" "geometry.rkt" "documents.rkt" "paths.rkt"
                       "table.rkt" "binding.rkt" "command.rkt" "hooks.rkt" "layer.rkt"
                       "action.rkt" "policy.rkt" "face.rkt" "theme.rkt" "wrap.rkt" "overlay.rkt"
                       "runner.rkt" "pipeline.rkt" "render.rkt"))

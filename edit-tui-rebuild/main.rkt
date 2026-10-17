#lang racket

;;; edit-tui-rebuild/main.rkt —— 重建骨架的公共面
;;;
;;; 只聚合“给宿主用”的模块；实现模块仍可直接 require。
;;;
;;;   base/      id / event / effect / transition / keymap
;;;   model/     state / workspace / input / chrome
;;;   env/       environment / role / mode / scope / command / defaults
;;;   dispatch/  pipeline（event -> transition）
;;;   effects/   engine（唯一 core 拥有者）/ interpreter
;;;   projection/ render（state + engine -> bytes）
;;;   bootstrap/ default-env（默认命令/键表）
;;;   runtime/   run-app（唯一不纯的装配/循环）
;;;
;;; 典型用法见 demo/basic.rkt。

(require "base/id.rkt"
         "base/event.rkt"
         "base/effect.rkt"
         "base/transition.rkt"
         "base/keymap.rkt"
         "base/status.rkt"
         "model/state.rkt"
         "model/workspace.rkt"
         "model/input.rkt"
         "model/chrome.rkt"
         "env/environment.rkt"
         "env/role.rkt"
         "env/mode.rkt"
         "env/scope.rkt"
         "env/command.rkt"
         "env/rule.rkt"
         "env/doc-type.rkt"
         "env/defaults.rkt"
         "dispatch/pipeline.rkt"
         "effects/engine.rkt"
         "effects/interpreter.rkt"
         "projection/render.rkt"
         "bootstrap/defaults.rkt"
         "runtime/run.rkt")

(provide (all-from-out "base/id.rkt"
                       "base/event.rkt"
                       "base/effect.rkt"
                       "base/transition.rkt"
                       "base/keymap.rkt"
                       "base/status.rkt"
                       "model/state.rkt"
                       "model/workspace.rkt"
                       "model/input.rkt"
                       "model/chrome.rkt"
                       "env/environment.rkt"
                       "env/role.rkt"
                       "env/mode.rkt"
                       "env/scope.rkt"
                       "env/command.rkt"
                       "env/rule.rkt"
                       "env/doc-type.rkt"
                       "env/defaults.rkt"
                       "dispatch/pipeline.rkt"
                       "effects/engine.rkt"
                       "effects/interpreter.rkt"
                       "projection/render.rkt"
                       "bootstrap/defaults.rkt"
                       "runtime/run.rkt"))

#lang racket

;;; edit-tui-rebuild/main.rkt —— 重建骨架的公共面
;;;
;;; 只聚合“给宿主用”的模块；实现模块仍可直接 require。
;;;
;;;   base/      id / event / effect / transition / keymap / status
;;;   model/     state / workspace / input / chrome / resources / filetree
;;;   env/       environment / role / mode / scope / command / rule / doc-type /
;;;              input-command / defaults
;;;   dispatch/  pipeline（event -> transition）
;;;   effects/   engine（唯一 core 拥有者）/ interpreter
;;;   projection/ geometry / render / status / resources / filetree
;;;   bootstrap/ panel（通用装配）/ plugin（插件描述符+纯装配）/ defaults / commands /
;;;              chrome / resource-panel + resource-commands /
;;;              filetree-panel + filetree-commands
;;;   runtime/   run-app（唯一不纯的装配/循环）
;;;
;;; 典型用法见 demo/basic.rkt。
;;;
;;; 插件化现状（暂定）：filetree / resource 仍是 bootstrap 的一部分，
;;; 但装配动作已收敛到 bootstrap/panel.rkt，每帧刷新通过
;;; `environment.panel-syncs` 注册，runtime 不认识具体面板。

;;; ── base ──
(require "base/id.rkt"
         "base/event.rkt"
         "base/effect.rkt"
         "base/transition.rkt"
         "base/keymap.rkt"
         "base/status.rkt")

;;; ── model ──
(require "model/state.rkt"
         "model/workspace.rkt"
         "model/input.rkt"
         "model/chrome.rkt"
         "model/resources.rkt"
         "model/filetree.rkt")

;;; ── env ──
(require "env/environment.rkt"
         "env/role.rkt"
         "env/mode.rkt"
         "env/scope.rkt"
         "env/command.rkt"
         "env/rule.rkt"
         "env/doc-type.rkt"
         "env/input-command.rkt"
         "env/defaults.rkt")

;;; ── dispatch / effects / projection ──
(require "dispatch/pipeline.rkt"
         "effects/engine.rkt"
         "effects/interpreter.rkt"
         "projection/geometry.rkt"
         "projection/render.rkt"
         "projection/status.rkt"
         "projection/resources.rkt"
         "projection/filetree.rkt")

;;; ── bootstrap ──
(require "bootstrap/panel.rkt"
         "bootstrap/plugin.rkt"
         "bootstrap/defaults.rkt"
         "bootstrap/commands.rkt"
         (except-in "bootstrap/chrome.rkt" input-show)
         "bootstrap/resource-panel.rkt"
         "bootstrap/resource-commands.rkt"
         "bootstrap/filetree-panel.rkt"
         "bootstrap/filetree-commands.rkt")

;;; ── 输入栏 API + runtime ──
(require "input.rkt"
         "runtime/run.rkt")

;;; ── 导出 ──

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
                       "model/resources.rkt"
                       "model/filetree.rkt"
                       "env/environment.rkt"
                       "env/role.rkt"
                       "env/mode.rkt"
                       "env/scope.rkt"
                       "env/command.rkt"
                       "env/rule.rkt"
                       "env/doc-type.rkt"
                       "env/input-command.rkt"
                       "env/defaults.rkt"
                       "dispatch/pipeline.rkt"
                       "effects/engine.rkt"
                       "effects/interpreter.rkt"
                       "projection/geometry.rkt"
                       "projection/render.rkt"
                       "projection/status.rkt"
                       "projection/resources.rkt"
                       "projection/filetree.rkt"
                       "bootstrap/panel.rkt"
                       "bootstrap/plugin.rkt"
                       "bootstrap/defaults.rkt"
                       "bootstrap/commands.rkt"
                       "bootstrap/resource-panel.rkt"
                       "bootstrap/resource-commands.rkt"
                       "bootstrap/filetree-panel.rkt"
                       "bootstrap/filetree-commands.rkt"
                       "input.rkt"
                       "runtime/run.rkt")
         (all-from-out "bootstrap/chrome.rkt"))

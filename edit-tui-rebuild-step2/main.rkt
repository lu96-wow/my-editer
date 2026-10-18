#lang racket

;;; edit-tui/main.rkt —— 公共面（只 require / provide）
;;;
;;; layer  : main
;;; effect : 无（不构造、不执行任何东西）
;;;
;;; 层序（依赖只能往下）：
;;;
;;;   base      纯词汇：id / event / effect / transition / keymap / status-part
;;;   model     纯状态：state / workspace（含 float）/ layout / input / chrome / save
;;;   env       纯策略：environment / role / mode / scope / command / rule /
;;;             doc-type / input-command / plugin / defaults
;;;   effects   边界：engine（core 拥有者）/ panel（面板↔引擎）/ interpreter（IO）
;;;   projection 纯投影：geometry / float（浮层）/ status / render
;;;   dispatch  纯派发：context / rules / pipeline
;;;   chrome    框架 chrome：slot（status/input 槽）/ input（输入栏 API）
;;;   bootstrap 装配：panel-spec 落地 / commands/* / defaults（core-env）
;;;   plugins   内置插件：filetree / resource / builtin（core-env + 插件 = default-env）
;;;   runtime   壳：run（事件循环）/ tui-adapter
;;;
;;; 有副作用的模块只有这几个（其余都必须纯，见 test/layers.rkt 的白名单）：
;;;   effects/engine.rkt      core buffer/view 的唯一可变拥有者
;;;   effects/panel.rkt       创建/销毁面板的 core 对象、写面板 buffer
;;;   effects/interpreter.rkt 文件 IO / 文档开关 / 保存 / 退出
;;;   chrome/slot.rkt         安装 status/input core view 并写 status buffer
;;;   plugins/*/panel.rkt     写各自面板的 buffer
;;;   plugins/filetree/scan.rkt        读目录
;;;   plugins/filetree/commands.rkt    建/删文件（effect）、存在性检查
;;;   runtime/run.rkt         终端 IO、线程、渲染输出
;;;
;;; 直接 require 实现模块也可以；这里只是给宿主一个入口。

;;; ── base ──
(require "base/id.rkt"
         "base/event.rkt"
         "base/effect.rkt"
         "base/transition.rkt"
         "base/keymap.rkt"
         "base/status-part.rkt")

;;; ── model ──
(require "model/state.rkt"
         "model/workspace.rkt"
         "model/layout.rkt"
         "model/input.rkt"
         "model/chrome.rkt"
         "model/save.rkt"
         "model/face-decor.rkt")

;;; ── env ──
(require "env/environment.rkt"
         "env/role.rkt"
         "env/mode.rkt"
         "env/scope.rkt"
         "env/command.rkt"
         "env/rule.rkt"
         "env/doc-type.rkt"
         "env/input-command.rkt"
         "env/hook.rkt"
         "env/panel-spec.rkt"
         "env/extension.rkt"
         "env/plugin.rkt"
         "env/defaults.rkt")

;;; ── effects ──
(require "effects/engine.rkt"
         "effects/paint.rkt"
         "effects/panel.rkt"
         "effects/interpreter.rkt")

;;; ── projection ──
(require "projection/geometry.rkt"
         "projection/float.rkt"
         "projection/status.rkt"
         "projection/render.rkt")

;;; ── dispatch ──
(require "dispatch/context.rkt"
         "dispatch/rules.rkt"
         "dispatch/pipeline.rkt")

;;; ── chrome ──
(require (except-in "chrome/slot.rkt" input-show)
         "chrome/input.rkt")

;;; ── bootstrap ──
(require "effects/panel.rkt"
         "bootstrap/commands/table.rkt"
         "bootstrap/defaults.rkt")

;;; ── plugins ──
(require "plugins/filetree/model.rkt"
         "plugins/filetree/scan.rkt"
         "plugins/filetree/lines.rkt"
         "plugins/filetree/panel.rkt"
         "plugins/filetree/commands.rkt"
         "plugins/filetree/plugin.rkt"
         "plugins/resource/model.rkt"
         "plugins/resource/lines.rkt"
         "plugins/resource/panel.rkt"
         "plugins/resource/commands.rkt"
         "plugins/resource/plugin.rkt"
         "plugins/builtin.rkt")

;;; ── runtime ──
(require "runtime/tui-adapter.rkt"
         "runtime/run.rkt")

;;; ── 导出 ──

(provide (all-from-out "base/id.rkt"
                       "base/event.rkt"
                       "base/effect.rkt"
                       "base/transition.rkt"
                       "base/keymap.rkt"
                       "base/status-part.rkt")
         (all-from-out "model/state.rkt"
                       "model/workspace.rkt"
                       "model/layout.rkt"
                       "model/input.rkt"
                       "model/chrome.rkt"
                       "model/save.rkt"
                       "model/face-decor.rkt")
         (all-from-out "env/environment.rkt"
                       "env/role.rkt"
                       "env/mode.rkt"
                       "env/scope.rkt"
                       "env/command.rkt"
                       "env/rule.rkt"
                       "env/doc-type.rkt"
                       "env/input-command.rkt"
                       "env/hook.rkt"
                       "env/panel-spec.rkt"
                       "env/extension.rkt"
                       "env/plugin.rkt"
                       "env/defaults.rkt")
         (all-from-out "effects/engine.rkt"
                       "effects/paint.rkt"
                       "effects/panel.rkt"
                       "effects/interpreter.rkt")
         (all-from-out "projection/float.rkt")
         (all-from-out "projection/geometry.rkt"
                       "projection/status.rkt"
                       "projection/render.rkt")
         (all-from-out "dispatch/context.rkt"
                       "dispatch/rules.rkt"
                       "dispatch/pipeline.rkt")
         (all-from-out "chrome/input.rkt")
         (all-from-out "effects/panel.rkt"
                       "bootstrap/commands/table.rkt"
                       "bootstrap/defaults.rkt")
         (all-from-out "plugins/filetree/model.rkt"
                       "plugins/filetree/scan.rkt"
                       "plugins/filetree/lines.rkt"
                       "plugins/filetree/panel.rkt"
                       "plugins/filetree/commands.rkt"
                       "plugins/filetree/plugin.rkt"
                       "plugins/resource/model.rkt"
                       "plugins/resource/lines.rkt"
                       "plugins/resource/panel.rkt"
                       "plugins/resource/commands.rkt"
                       "plugins/resource/plugin.rkt"
                       "plugins/builtin.rkt")
         (all-from-out "runtime/tui-adapter.rkt"
                       "runtime/run.rkt")
         (all-from-out "chrome/slot.rkt"))

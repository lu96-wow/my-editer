#lang racket

;;; edit4/core.rkt —— 命令层入口（再导出）
;;;
;;;   event    输入事件
;;;   world    World（布局 + 浮窗 + 焦点 + prefix + drag）
;;;   drag     手势状态
;;;   command  命令数据 + 注册表 + 求值
;;;   keymap   绑定 / 键表
;;;   dispatch 作用域 + 输入求值
;;;   commands 基础命令 / 键表 / 作用域

(provide (all-from-out "core/event.rkt"
                       "core/world.rkt"
                       "core/drag.rkt"
                       "core/command.rkt"
                       "core/keymap.rkt"
                       "core/dispatch.rkt"
                       "core/commands.rkt"))

(require "core/event.rkt"
         "core/world.rkt"
         "core/drag.rkt"
         "core/command.rkt"
         "core/keymap.rkt"
         "core/dispatch.rkt"
         "core/commands.rkt")

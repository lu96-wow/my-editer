#lang racket

;;; edit4/core.rkt —— 命令层入口（再导出）
;;;
;;;   event    输入事件
;;;   effect   一次性 IO（数据）
;;;   world    World（布局 + 浮窗 + 焦点 + prefix + drag + content）
;;;   drag     手势状态
;;;   command  命令数据 + 注册表 + 求值
;;;   keymap   绑定 / 键表
;;;   scope    作用域注册表
;;;   dispatch 输入求值
;;;   base     基础命令集（窗口 + 指针）+ 基础键表 / 作用域
;;;
;;; 窗口命令实现在 core/window.rkt，指针命令在 core/pointer.rkt。

(provide (all-from-out "core/event.rkt"
                       "core/effect.rkt"
                       "core/world.rkt"
                       "core/drag.rkt"
                       "core/command.rkt"
                       "core/keymap.rkt"
                       "core/scope.rkt"
                       "core/dispatch.rkt"
                       "core/base.rkt"))

(require "core/event.rkt"
         "core/effect.rkt"
         "core/world.rkt"
         "core/drag.rkt"
         "core/command.rkt"
         "core/keymap.rkt"
         "core/scope.rkt"
         "core/dispatch.rkt"
         "core/base.rkt")

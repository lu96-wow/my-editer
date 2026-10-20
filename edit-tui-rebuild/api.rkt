#lang racket

;;; edit-tui-rebuild/api.rkt —— 统一 API 面
;;;
;;; 只聚合：
;;;   skeleton/api.rkt   骨架（布局 / 资源 / 焦点 / face / 命令 / 投影 / engine）
;;;   render/api.rkt     渲染入口（runtime 侧的渲染实现）
;;;   各插件 api.rkt     edit / chrome / filetree
;;;   app/api.rkt        事件 / 状态 / action / placement / step
;;;   runtime/api.rkt    engine / actions / render / sync / tui adapter / loop
;;;
;;; 不 require 任何实现模块。

(require "skeleton/api.rkt"
         "render/api.rkt"
         "app/api.rkt"
         "edit/api.rkt"
         "chrome/api.rkt"
         "filetree/api.rkt"
         "runtime/api.rkt")

(provide (all-from-out "skeleton/api.rkt"
                       "render/api.rkt"
                       "app/api.rkt"
                       "edit/api.rkt"
                       "chrome/api.rkt"
                       "filetree/api.rkt"
                       "runtime/api.rkt"))

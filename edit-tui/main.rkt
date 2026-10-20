#lang racket

;;; edit-tui-rebuild/main.rkt —— 公共入口（唯一聚合点）
;;;
;;; api 不是一层：每个领域目录的 api.rkt 是它的「对外面」。
;;; 这里按层聚合，不再有顶层 api.rkt：
;;;
;;;   core/skeleton.rkt   骨架（布局 / 资源 / 焦点 / face / 命令 / 投影 / engine）
;;;   render/api.rkt     渲染入口
;;;   插件 api.rkt       edit / chrome / filetree
;;;   app/api.rkt        宿主用的 app 面（state / action / placement / step）
;;;   boot/api.rkt         actions / render / sync / tui-adapter / loop
;;;
;;; 插件不要 require 本文件（会成环）：插件只 require core/skeleton.rkt
;;; 和 app 基础值（app/state.rkt 等）。

(require "core/skeleton.rkt"
         "render/api.rkt"
         "edit/api.rkt"
         "chrome/api.rkt"
         "filetree/api.rkt"
         "app/api.rkt"
         "boot/api.rkt")

(provide (all-from-out "core/skeleton.rkt"
                       "render/api.rkt"
                       "edit/api.rkt"
                       "chrome/api.rkt"
                       "filetree/api.rkt"
                       "app/api.rkt"
                       "boot/api.rkt"))

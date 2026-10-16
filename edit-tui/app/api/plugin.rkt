#lang racket

;;; api/plugin.rkt —— 公共 API 面：插件注册 + 声明式载入
;;;
;;; 转发 app/plugin.rkt：define-plugin! / panel-spec / plugins-apply / plugins-list。
;;; 插件模块顶层调用这些接口，require 即注册；启动时 plugins-apply 折进当前 world。
;;; 此文件只转发，不放逻辑。

(require "../plugin.rkt")
(provide (all-from-out "../plugin.rkt"))

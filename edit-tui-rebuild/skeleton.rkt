#lang racket

;;; edit-tui-rebuild/skeleton.rkt —— 骨架入口（插件只 require 这个）
;;;
;;; 骨架 = 编辑器基础设施，不含任何具体插件：
;;;   base     几何 / 文本值（core 词汇的再导出）
;;;   panel    面板资源
;;;   config   面板规则
;;;   layout   split tree / solve / 结构编辑
;;;   focus    焦点导航
;;;   face     face 值
;;;   resource 资源 / 保存 / 退出 / prompt
;;;   command  命令表 / 键 token
;;;   projection  layout -> core panel（渲染 / 命中投影）
;;;   engine   core buffer / view 的持有者（插件写 UI view 的入口）
;;;
;;; 插件（edit / chrome / filetree）组合这些 + app/state 完成功能；
;;; 插件之间只经对方 api.rkt；runtime 才解释 action / 做 IO / 渲染。

(require "base/api.rkt"
         "panel/api.rkt"
         "config/api.rkt"
         "layout/api.rkt"
         "focus/api.rkt"
         "face/api.rkt"
         "resource/api.rkt"
         "command/api.rkt"
         "projection/api.rkt"
         "engine/api.rkt")

(provide (all-from-out "base/api.rkt"
                       "panel/api.rkt"
                       "config/api.rkt"
                       "layout/api.rkt"
                       "focus/api.rkt"
                       "face/api.rkt"
                       "resource/api.rkt"
                       "command/api.rkt"
                       "projection/api.rkt"
                       "engine/api.rkt"))

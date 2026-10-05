#lang racket

;;; lab/plugin/api.rkt —— 插件协议
;;;
;;; 插件 = 一对纯函数，维护自己的增量状态：
;;;   open   : text path           -> (values state fills)           首次 / 整篇
;;;   change : state edits lines path -> (values state fills)        增量
;;;     edits = (listof edit)，edit = (list l0 c0 l1 c1 inserted)（同一编辑前坐标系）
;;;     lines = vector of string   新文本行
;;;     fills = (listof fill)，fill = (list l0 c0 l1 c1 face)（半开区间，全量）
;;;
;;; 因为不改文本，state/fills 可以放在后台进程里维护；只有 job 取回 fills。
;;; plugin 结构体留在主进程；后台进程按 name 查同一份 registry。

(provide (struct-out plugin))

(struct plugin (name priority open change) #:transparent)
;; name     : symbol              后台进程按名字查同一个 open/change
;; priority : exact-integer       越大越后应用（覆盖小 priority）

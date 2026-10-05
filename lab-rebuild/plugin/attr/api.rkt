#lang racket

;;; lab-rebuild/plugin/attr/api.rkt —— 插件协议
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
;;;
;;; **应用顺序 = registry 顺序**（无优先级字段）。多个插件写同一格时不去掉谁，
;;; 而是把 face 依次叠成 face-stack；主题逐分量合并（后层覆盖前层，某层 #f 的分量不覆盖），
;;; 所以「括号背景」和「语法前景」可以共存。

(provide (struct-out plugin))

(struct plugin (name open change) #:transparent)
;; name : symbol         后台进程按名字查同一个 open/change
;; open / change : 见上

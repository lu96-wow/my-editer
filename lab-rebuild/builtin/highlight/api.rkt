#lang racket

;;; lab-re-rebuild/plugin/attr/api.rkt —— 插件协议
;;;
;;; 插件 = 「是否适用」谓词 + 一对纯函数，维护自己的增量状态：
;;;   applies? : path text            -> boolean                    该文档是否启用本插件
;;;   open     : text path            -> (values state fills)       首次 / 整篇
;;;   change   : state edits lines path -> (values state fills)     增量
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
;;;
;;; **按文档启用**：「这次启用哪些」是 config（名字目录）；「这个文档适用哪些」由各插件
;;; 的 `applies?` 决定（按扩展名 / #lang 等）。machine / manager 只对自己文档的插件集
;;; 派活、等齐、写回，不适用插件根本不参与。

(provide (struct-out plugin) plugins-for)

(struct plugin (name applies? open change) #:transparent)
;; name     : symbol         后台进程按名字查同一个 open/change
;; applies? / open / change : 见上

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((plugin-applies? p) path text))
    p))

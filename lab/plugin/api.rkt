#lang racket

(require "../base/face.rkt")

;;; lab/plugin/api.rkt —— 插件协议
;;;
;;; 插件 = 一个**纯函数**：文本快照 → 装饰。因为不改文本，可以整体丢到后台进程跑。
;;;
;;; 输入 job： (job text path)
;;;   text : string（整篇文本快照）
;;;   path : 文件路径 / #f（给以后按语言做插件的用；括号插件不用）
;;; 输出： (listof fill)，fill = (list l0 c0 l1 c1 face)
;;;   —— 与 core 的 document-highlight-fill-batch 同一格式（半开区间）。
;;;
;;; 关键点：
;;;   · plugin 结构体**留在主进程**；后台进程只收到 name，用同一份 registry 查 compute。
;;;   · job 用 #:prefab，face（如 bracket-depth）也 #:prefab，才能跨 place 序列化。
;;;   · compute 必须是纯函数（不碰 editor / 终端）。

(provide (struct-out plugin) (struct-out job))

(struct plugin (name priority compute) #:transparent)
;; name     : symbol                后台进程按名字查同一个 compute
;; priority : exact-integer        越大越后应用（覆盖小 priority 的插件）
;; compute  : (-> job (listof fill))

(struct job (text path) #:prefab)

;; fill = (list l0 c0 l1 c1 face)：见 core document-highlight-fill-batch。

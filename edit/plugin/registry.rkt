#lang racket

;;; edit/plugin/registry.rkt —— document 插件协议 + 按文档筛选（纯）
;;;
;;; document 插件 = 「是否适用」谓词 + 一个带状态的纯变换：
;;;   applies? : path text -> boolean
;;;   run      : state ctx -> (values state (listof fill))     state=#f 表示首次
;;;   ctx      : (doc-ctx text path point)                     point = (cons line col) | #f
;;;   fill     = (list l0 c0 l1 c1 face)                       半开区间
;;; face = symbol | palette-color | face-stack（见 core/face.rkt）。
;;;
;;; 插件不持可变要求：state 由 session 按 did 保存、逐次传入（undo 会得到旧 state）。
;;; 无状态插件忽略 state 返回 #f。fills 是 (text, point, state) 的纯函数；
;;; 「结果何时写回」交给 session 的渲染前步骤（按文档 handle 判新旧）。
;;;
;;; **应用顺序 = 目录顺序**：多个插件写同一格时按顺序 face-compose 成 face-stack；
;;; 主题逐分量合并，于是「词色」和「关键字色」可以共存（后者后写覆盖前者）。

(provide (struct-out doc-ctx) (struct-out doc-plugin) plugins-for)

(struct doc-ctx (text path point) #:transparent)
;; text  : string
;; path  : path | #f
;; point : (cons exact-integer exact-integer) | #f   焦点视图光标 (line . col)（供活动词 / 前缀）

(struct doc-plugin (name applies? run) #:transparent)
;; name     : symbol
;; applies? : path text -> boolean
;; run      : state ctx -> (values state (listof fill))

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((doc-plugin-applies? p) path text))
    p))

#lang racket

;;; edit/plugin/registry.rkt —— document 插件协议 + 按文档筛选（纯）
;;;
;;; document 插件 = 「是否适用」谓词 + 一对纯函数，维护自己的**增量**状态：
;;;   applies? : path text -> boolean
;;;   open     : text path -> (values state fills)                首次 / 整篇
;;;   change   : state dirty active path -> (values state fills)  增量（只算脏行）
;;;     dirty  : (listof (cons line string))   需重算的行（升序去重；编辑后坐标）
;;;     active : (list line start end) | #f     活动词（本次编辑处），本次跳过
;;;     fills  : (listof fill)  fill = (list l0 c0 l1 c1 face)   只覆盖 dirty 各行
;;; face = symbol | palette-color | face-stack（见 core/face.rkt）。
;;;
;;; 状态随 document 版本走（见 session/plugin.rkt 的文档槽）：每次编辑 fork 出新状态，
;;; 旧版本不动 → undo 恢复旧 document 即得旧 state；只有脏行被重算与重绘。
;;; 无状态插件忽略 state 返回 #f。
;;;
;;; **应用顺序 = 目录顺序**：多个插件写同一格时按顺序 face-compose 成 face-stack；
;;; 主题逐分量合并，于是「词色」和「关键字色」可以共存（后者后写覆盖前者）。

(provide (struct-out doc-plugin) (struct-out plugin-spec)
         plugins-for)

(struct doc-plugin (name applies? open change) #:transparent)
;; name     : symbol
;; applies? : path text -> boolean
;; open     : text path -> (values state (listof fill))
;; change   : state dirty active path -> (values state (listof fill))

;; 插件包：一个插件 = 名字 + 全局安装 + 它带的 document 插件。
;; install : session -> session（注册 hook / layer / handler / panel 等贡献）
(struct plugin-spec (name install doc-plugins) #:transparent)

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((doc-plugin-applies? p) path text))
    p))

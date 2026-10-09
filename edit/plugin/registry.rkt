#lang racket

;;; edit/plugin/registry.rkt —— document 插件协议 + 按文档筛选（纯）
;;;
;;; document 插件 = 「是否适用」谓词 + 一对纯函数，维护自己的增量状态：
;;;   applies? : path text -> boolean
;;;   open     : text path -> (values state fills)          首次 / 整篇
;;;   change   : state change-ctx -> (values state fills)   增量推进，但产出**整篇** fills
;;;     fills  : (listof fill)  fill = (list l0 c0 l1 c1 face)，可跨行
;;; face = symbol | palette-color | palette-bg | face-stack（见 core/face.rkt）。
;;;
;;; 关键：**change 返回整篇 fills**（对齐 lab）。增量只省「重算」，
;;; 写回是「清空整条 face 轨道 + 重写全部 fills」——行号平移 / 行数变化都不会错。
;;; 状态随 document 版本走（见 session/plugin.rkt 的文档槽）：undo 恢复旧 document 即得旧 state。
;;;
;;; **应用顺序 = 目录顺序**：多层按顺序 face-compose 成 face-stack；
;;; 主题逐分量合并，于是「括号背景」和「语法前景」共存。

(provide (struct-out doc-plugin) (struct-out change-ctx)
         (struct-out plugin-spec) plugins-for)

(struct doc-plugin (name applies? open change) #:transparent)
;; name     : symbol
;; applies? : path text -> boolean
;; open     : text path -> (values state (listof fill))
;; change   : state change-ctx -> (values state (listof fill))

;; 增量编辑上下文（会话侧构造）。
(struct change-ctx (edits active lines path) #:transparent)
;; edits  : (listof (list l0 c0 l1 c1))   本次编辑（编辑后坐标）
;; active : (list line start end) | #f    活动词（高亮类插件用；其余忽略）
;; lines  : (vectorof string)             新文本全部行
;; path   : path

;; 插件包：一个插件 = 名字 + 全局安装 + 它带的 document 插件。
;; install : session -> session（注册 hook / layer / handler / panel 等贡献）
(struct plugin-spec (name install doc-plugins) #:transparent)

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((doc-plugin-applies? p) path text))
    p))

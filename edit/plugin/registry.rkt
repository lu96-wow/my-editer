#lang racket

;;; edit/plugin/registry.rkt —— document 插件协议 + 按文档筛选（纯）
;;;
;;; document 插件 = 「是否适用」谓词 + 一对纯函数，维护自己的**增量**状态：
;;;   applies? : path text -> boolean
;;;   open     : text path -> (values state fills)                 首次 / 整篇
;;;   change   : state change-ctx -> (values state touched fills)  增量
;;;     touched : (listof exact-integer)  本次 fills 变化到的行（需清 face 后重画）
;;;     fills   : (listof fill)           **单行** fills（l0 = l1 = 行号）；覆盖 touched
;;; face = symbol | palette-color | palette-bg | face-stack（见 core/face.rkt）。
;;;
;;; 为什么 change 要声明 touched：括号背景这类插件的重画区域是**跨行**的，
;;; 而写回是「清 touched 行、再叠加**所有**插件在这些行的 fills」——这样宽区域
;;; 插件的重画不会抹掉同行上别的插件（语法前景 / 词色）的贡献。
;;;
;;; 状态随 document 版本走（见 session/plugin.rkt 的文档槽）：每次编辑 fork 出新状态，
;;; 旧版本不动 → undo 恢复旧 document 即得旧 state。
;;;
;;; **应用顺序 = 目录顺序**：同一行多个插件按顺序 face-compose 成 face-stack；
;;; 主题逐分量合并，于是「括号背景」和「语法前景」可以共存。

(provide (struct-out doc-plugin) (struct-out change-ctx)
         (struct-out plugin-spec) plugins-for)

(struct doc-plugin (name applies? open change) #:transparent)
;; name     : symbol
;; applies? : path text -> boolean
;; open     : text path -> (values state (listof fill))
;; change   : state change-ctx -> (values state (listof line) (listof fill))

;; 增量编辑上下文（会话侧构造；插件按需取用）。
(struct change-ctx (dirty edits active line-ref line-count path) #:transparent)
;; dirty      : (listof (cons line string))   编辑直接波及的行（升序去重）
;; edits      : (listof (list l0 c0 l1 c1))   本次编辑（编辑后坐标）
;; active     : (list line start end) | #f    活动词（高亮类插件用；其余忽略）
;; line-ref   : exact-integer -> string       新文本第 n 行（越界 → ""）
;; line-count : exact-integer                 新文本行数
;; path       : path

;; 插件包：一个插件 = 名字 + 全局安装 + 它带的 document 插件。
;; install : session -> session（注册 hook / layer / handler / panel 等贡献）
(struct plugin-spec (name install doc-plugins) #:transparent)

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((doc-plugin-applies? p) path text))
    p))

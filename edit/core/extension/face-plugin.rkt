#lang racket

;;; edit-rebuild/core/extension/face-plugin.rkt —— face 插件协议 + 按文档筛选（纯）
;;;
;;; face 插件 = 「是否适用」谓词 + 一对纯函数，维护自己的增量状态与**层**：
;;;   applies? : path text -> boolean
;;;   open     : text-track path -> (values state layer)
;;;   change   : state layer face-ctx -> (values state layer dirty)
;;;
;;; 层（layer）= 一条 track，行 payload = (vectorof face) | #f（#f = 该行无贡献）。
;;; **输出是层、增量按行**：change 只重扫脏行并返回脏行号；未变行由 track 结构共享。
;;; 于是每次编辑是 O(脏行)，而不是 O(全文)；写回也只碰脏行（见 session/plugin.rkt）。
;;;
;;; 状态随 document 版本走（见 session/plugin.rkt 的文档槽）：undo 恢复旧 document 即得旧状态。
;;;
;;; **应用顺序 = 目录顺序**：多层按顺序 face-compose 成 face-stack；
;;; 主题逐分量合并，于是「括号背景」和「语法前景」共存。
;;;
;;; face-ctx 只给中性结构（track / change / 光标点）；「什么算一个词」这类词法在 core/lex.rkt。
;;; 插件可以看光标**判定「正在编辑的词」是否已编辑完**（光标离开＝编辑完），
;;; 但**不得**把光标下的词当成「正在编辑」——那样光标移动就会改色。

(require "../face/line-scan.rkt")

(provide (struct-out face-plugin) (struct-out face-ctx) plugins-for)

(struct face-plugin
  (name applies? open change)
  #:transparent)
;; name     : symbol
;; applies? : path text -> boolean
;; open     : text-track path -> (values state layer)
;; change   : state layer face-ctx -> (values state layer dirty)
;; layer    : track，行 payload = (vectorof face) | #f

;; 增量编辑上下文（会话侧构造）。
(struct face-ctx (old-text new-text changes dirty path cursor)
  #:transparent)
;; old-text/new-text : track                  编辑前 / 后文本轨（不必物化）
;; changes : (listof change)                  本次编辑（core，编辑前 / 后坐标；空 = 纯光标移动）
;; dirty   : dirty                            changes 直接波及的整行（新坐标）
;; path    : path
;; cursor  : (cons line col) | #f              编辑视图当前光标（不在本文档 → #f）
;;         插件可据它判定「正在输入的词」是否已编辑完（光标离开）；
;;         但插件不得据它把光标下的词当成「正在输入」——光标移动不该改色。

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((face-plugin-applies? p) path text))
    p))

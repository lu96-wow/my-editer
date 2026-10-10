#lang racket

;;; edit-rebuild/core/extension/face-plugin.rkt —— face 插件协议 + 按文档筛选（纯）
;;;
;;; face 插件 = 「是否适用」谓词 + 一对纯函数，维护自己的增量状态与**层**：
;;;   applies? : path text -> boolean
;;;   open     : text-track path -> (values state layer)
;;;   change   : state layer face-ctx -> (values state layer (listof line-index))
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
;;; face-ctx 只给中性结构（track / change）；「什么算一个词」这类词法在 core/lex.rkt。

(require "../face/line-scan.rkt")

(provide (struct-out face-plugin) (struct-out face-ctx)
         plugins-for active-dirty)

(struct face-plugin
  (name applies? open change)
  #:transparent)
;; name     : symbol
;; applies? : path text -> boolean
;; open     : text-track path -> (values state layer)
;; change   : state layer face-ctx -> (values state layer dirty)
;; layer    : track，行 payload = (vectorof face) | #f

;; 增量编辑上下文（会话侧构造）。
(struct face-ctx (old-text new-text changes dirty path active prev-active)
  #:transparent)
;; old-text/new-text : track                  编辑前 / 后文本轨（不必物化）
;; changes : (listof change)                  本次编辑（core，编辑前 / 后坐标）
;; dirty   : dirty                            changes 直接波及的整行（新坐标）
;; path    : path
;; active  : (list line start end) | #f       当前活动词（正在输入处）
;; prev-active : 同 active，上一次的          字面 / 关键字插件也要重扫它，避免旧词永不上色

;; 活动词所在行并入基础脏行。
(define (active-line a) (and a (car a)))
(define (active-dirty ctx)
  (dirty-union (face-ctx-dirty ctx)
               (dirty-lines (filter values (list (active-line (face-ctx-prev-active ctx))
                                                 (active-line (face-ctx-active ctx)))))))

;; 从启用目录里挑出适用于该文档的插件（保持目录顺序）。
(define (plugins-for plugins path text)
  (for/list ([p (in-list plugins)]
             #:when ((face-plugin-applies? p) path text))
    p))

#lang racket

;;; edit-rebuild/core/config/layout.rkt —— 布局（直接用 core 布局原语写）
;;;
;;; 布局就是 split/slot 的树，没有中间 DSL。slot 名（slot-side / slot-editor /
;;; slot-bottom / slot-docs，见 core/ids.rkt）是运行时 assembly 按名填内容的接口。
;;;   layout-left : 文件树（+ buffers）在左
;;;   layout-top  : 文件树（+ buffers）在上
;;;
;;; 编辑区列表顺序（自上而下）：editor / docs（文档区）/ bottom（状态行等）。
;;; docs 贴在底部区**上方**：文档窗出现时顶起编辑区，状态行仍在最底，且横跨编辑区宽。

(require "../geometry/layout.rkt"
         "../ids.rkt")

(provide layout-left layout-top)

;; 左：side | (editor / docs / bottom)
(define layout-left
  (split 'lr (list (cons 26 (slot slot-side))
                   (cons 'flex (split 'tb (list (cons 'flex (slot slot-editor))
                                                (cons 1 (slot slot-docs))
                                                (cons 1 (slot slot-bottom))))))))

;; 上：side ───────
;;     (editor / docs / bottom)
(define layout-top
  (split 'tb (list (cons 8 (slot slot-side))
                   (cons 'flex (split 'tb (list (cons 'flex (slot slot-editor))
                                                (cons 1 (slot slot-docs))
                                                (cons 1 (slot slot-bottom))))))))

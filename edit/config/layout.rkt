#lang racket

;;; edit/config/layout.rkt —— 布局（直接用 core 布局原语写）
;;;
;;; 布局就是 split/slot 的树，没有中间 DSL。slot 名（'side/'editor/'bottom）是
;;; 运行时 assembly 按名填内容的接口。
;;;   layout-left : 文件树（+ buffers）在左
;;;   layout-top  : 文件树（+ buffers）在上

(require "../core/layout.rkt")

(provide layout-left layout-top)

;; 左：side | (editor / bottom)
(define layout-left
  (split 'lr (list (cons 26 (slot 'side))
                   (cons 'flex (split 'tb (list (cons 'flex (slot 'editor))
                                                (cons 2 (slot 'bottom))))))))

;; 上：side ───────
;;     (editor / bottom)
(define layout-top
  (split 'tb (list (cons 8 (slot 'side))
                   (cons 'flex (split 'tb (list (cons 'flex (slot 'editor))
                                                (cons 2 (slot 'bottom))))))))

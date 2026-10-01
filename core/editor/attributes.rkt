#lang racket

(require "state.rkt" "../text/document.rkt")

;;; editor/attributes.rkt —— 属性覆盖层：句柄式读写（O(1)，不碰 history）
;;;
;;; 高亮 / 只读存放在 document 的 box 里，是**可变覆盖层**。异步结果（LSP 高亮 /
;;; 诊断）写回 = 抓住请求时的 document 句柄，直接改 box：
;;;
;;;     (define doc (editor-view-document ed vid))    ; 请求时抓句柄
;;;     ...                                           ; 等解析
;;;     (editor-document-set-highlight! doc hl)       ; 结果回来 O(1)
;;;
;;;   · 当前版本        → 同一对象，立刻可见；
;;;   · redo / past 版本 → 同一对象，undo/redo 回去可见；
;;;   · 版本已被丢弃     → 句柄仍指旧对象，但不可达 → 静默失效，无副作用。
;;;
;;; 不新增 history 步、不重建快照、不做任何按版本查找（没有 O(深度)）。

(provide editor-view-document-handle
         editor-view-highlight-atom
         editor-view-readonly-atom
         editor-document-set-highlight!
         editor-document-set-readonly!
         editor-document-highlight-batch!
         editor-document-readonly-batch!
         editor-document-highlight-range-batch!
         editor-document-readonly-range-batch!)

;; 取某视图当前文档的句柄（= 连同不可变文本 + 可变属性原子）。
(define (editor-view-document-handle ed vid)
  (editor-view-document ed vid))

;; 取属性原子的 box 句柄（想直接 set-box! / 交给别的线程读时用）。
(define (editor-view-highlight-atom ed vid)
  (document-highlight-atom (editor-view-document ed vid)))
(define (editor-view-readonly-atom ed vid)
  (document-readonly-atom (editor-view-document ed vid)))

;; 写回：只动 box，editor 值不变，history 不动。
(define (editor-document-set-highlight! doc hl)
  (document-set-highlight! doc hl))
(define (editor-document-set-readonly! doc ro)
  (document-set-readonly! doc ro))

;; 批量写回：fills : (listof (list l0 c0 l1 c1 val))，一次 materialize、一次写 box。
;; 用于语义 token / 诊断这类"一串区间"的结果；仍不碰 history、不换 document。
(define (editor-document-highlight-batch! doc fills)
  (document-highlight-fill-batch doc fills))
(define (editor-document-readonly-batch! doc fills)
  (document-readonly-fill-batch doc fills))

;; 批量（range 版）：runs : (listof (list range val))。
(define (editor-document-highlight-range-batch! doc runs)
  (document-highlight-fill-range-batch doc runs))
(define (editor-document-readonly-range-batch! doc runs)
  (document-readonly-fill-range-batch doc runs))

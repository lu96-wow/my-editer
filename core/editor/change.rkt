#lang racket

(require "state.rkt" "../text/document.rkt")

;;; editor/change.rkt —— change 的 editor 侧读
;;;
;;; 本模块只有「需要 editor 解析文档」的取文本操作，按 did / vid 寻址。

(provide
 editor-document-change-text
 editor-view-change-text)

;; 取一次变更插入的文本（从该文档读）。
(define (editor-document-change-text ed did ch)
  (document-change-text (editor-document-handle ed did) ch))
(define (editor-view-change-text ed vid ch)
  (editor-document-change-text ed (view-did (editor-view-handle ed vid)) ch))

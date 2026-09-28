#lang racket

(require "state.rkt" "../text/document.rkt"
         "../text/base/change.rkt" "../text/base/range.rkt")

;;; editor/change.rkt —— 变更（change）的读
;;;
;;; 再导出 base 的 change / range 词汇表，外加两个需要解析文档的取文本。
;;; 对外名字由入口 core/editor.rkt 决定（改名成 editor-*）。

(provide
 ;; change / range 词汇表
 change change? change-before change-after
 range range? range-start range-end
 change-post-range change-map-point
 changes-map-point changes-map-point-literal
 change-empty? change-kind

 ;; 需要 editor 解析文档
 view-change-text)

;; 取一次变更插入的文本（从该视图的当前文档读；须紧接着该次编辑使用）。
(define (view-change-text ed vid ch)
  (document-change-text (editor-view-document ed vid) ch))


#lang racket

;;; lab-re-rebuild/kernel/editor-api.rkt —— lab-re-rebuild 唯一 require core-rebuild 的模块。
;;;
;;; core-rebuild 固定不动；其余模块只 require 本模块，不直接碰 core-rebuild。
;;; 与 core 的耦合收在这一个可替换的窄边界里。
;;;
;;; core-rebuild/editor.rkt 未转出、但特性需要的少数低层工具也在这里显式转出：
;;;   · 槽声明宏 define-document-slot + fork 上下文访问器
;;;   · 行序列化 / 轨切片（合成文档、增量编辑用）
;;;   · 端口批量填充（buffers / tree dock 合成文档用）

(require "../../core-rebuild/editor.rkt"
         (only-in "../../core-rebuild/text/slot-dsl.rkt"
                  define-document-slot)
         (only-in "../../core-rebuild/text/slots.rkt"
                  fork-ctx? fork-ctx-edit fork-ctx-changes fork-ctx-old-text fork-ctx-new-text)
         (only-in "../../core-rebuild/text/base/line.rkt"
                  string-normalize-newlines string->lines lines->string
                  line-slice line-length)
         (only-in "../../core-rebuild/text/base/track.rkt"
                  track-ref track-length track->list)
         (only-in "../../core-rebuild/text/document.rkt"
                  document-face-fill-batch document-readonly-fill-batch))

(provide (all-from-out "../../core-rebuild/editor.rkt")
         define-document-slot
         fork-ctx? fork-ctx-edit fork-ctx-changes fork-ctx-old-text fork-ctx-new-text
         string-normalize-newlines string->lines lines->string
         line-slice line-length
         track-ref track-length track->list
         document-face-fill-batch document-readonly-fill-batch
         editor-view-line-before)

;; 便利：光标前该行的文本（不含换行）。core 没暴露按行取文本，
;; 但暴露了 document-range-text —— 用它把「整篇取串 + 切行」降成 O(行)。
(define (editor-view-line-before ed vid p)
  (define did (editor-view-document-id ed vid))
  (define doc (editor-document-handle ed did))
  (document-range-text doc (range (point (point-line p) 0) p)))

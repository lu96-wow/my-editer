#lang racket

;;; lab-rebuild/kernel/editor-api.rkt —— lab-rebuild 唯一 require core 的模块。
;;;
;;; core 固定不动；其余模块只 require 本模块，不直接碰 core。
;;; lab-rebuild 与 core 的耦合收在这一个可替换的窄边界里。
;;;
;;; core/editor.rkt 未转出、但特性需要的少数低层工具（如行序列化）也在这里显式转出。

(require "../../core/editor.rkt"
         (only-in "../../core/text/base/line.rkt"
                  string-normalize-newlines string->lines lines->string))

(provide (all-from-out "../../core/editor.rkt")
         string-normalize-newlines string->lines lines->string
         editor-view-line-before)

;; 便利：光标前该行的文本（不含换行）。core 没暴露按行取文本，
;; 但暴露了 document-range-text —— 用它把「整篇取串 + 切行」降成 O(行)。
(define (editor-view-line-before ed vid p)
  (define did (editor-view-document-id ed vid))
  (define doc (editor-document-handle ed did))
  (document-range-text doc (range (point (point-line p) 0) p)))

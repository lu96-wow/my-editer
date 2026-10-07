#lang racket

;;; lab-rebuild/kernel/editor-api.rkt —— lab 唯一 require core 的模块。
;;;
;;; core 固定不动。其余 lab 模块只 require 本模块，不直接碰 core。
;;; 这样 lab 与 core 的耦合收在一个可替换的窄边界里。

(require "../../core/editor.rkt")

(provide (all-from-out "../../core/editor.rkt")
         editor-view-line-before)

;; lab 附加便利：光标前该行的文本（不含换行）。
;; core 没暴露「按行取文本」（内部 document-text / track-ref 被 except-out 挡了），
;; 但暴露了按区间的 document-range-text —— 用它把「整篇取串 + 切行」降成 O(行)。
(define (editor-view-line-before ed vid p)
  (define did (editor-view-document-id ed vid))
  (define doc (editor-document-handle ed did))
  (document-range-text doc (range (point (point-line p) 0) p)))

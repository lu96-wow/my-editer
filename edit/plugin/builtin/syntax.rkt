#lang racket

;;; edit/plugin/builtin/syntax.rkt —— 语法高亮插件（document 插件）
;;;
;;; 只对 Racket 源文件生效（applies? 按扩展名）；关键字按 keyword-list 位置取固定色号，
;;; face = (palette-color 'keyword 位置)，颜色由主题的 'keyword 色板决定。
;;; 全量重扫（本版不做增量）；「哪些文件参与」由 core/file-kind.rkt 决定。

(require "../../plugin/registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../config/syntax.rkt")

(provide syntax-plugin)

(define keyword-index
  (for/hash ([k (in-list keyword-list)] [i (in-naturals)]) (values k i)))

(define (syntax-fills text _path)
  (for/list ([tok (in-list (scan-words text))]
             #:when (hash-has-key? keyword-index (cadddr tok)))
    (match-define (list ln s e w) tok)
    (list ln s ln e (palette-color 'keyword (hash-ref keyword-index w)))))

(define syntax-plugin
  (doc-plugin 'syntax racket-applies? syntax-fills))

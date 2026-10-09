#lang racket

;;; edit/plugin/analysis/tools/analyze.rkt —— 工具门面（纯）
;;;
;;;   analyze-lex    便宜：词法 token（forest / 结构 / 缩进）
;;;   analyze-expand 贵：check-syntax 展开（语义 token / 定义 / 引用 / 诊断）
;;;   analyze        两者合一 → analysis-result
;;;
;;; 分两层是为了让调用方可以先拿词法结果、后拿展开结果（乐观）。本模块不依赖
;;; core / session / tui；expand 会执行代码，生产上必须经 worker.rkt。

(require "span.rkt"
         "lexer.rkt"
         "expand.rkt")

(provide analyze analyze-lex analyze-expand)

(define (analyze-lex path text)
  (lex-result path (lex-text text path)))

(define (analyze-expand path text)
  (expand-analyze path text))

(define (analyze path text [version 0])
  (analysis-result path version (analyze-lex path text) (analyze-expand path text)))

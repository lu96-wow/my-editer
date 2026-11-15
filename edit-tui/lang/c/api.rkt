#lang racket

;;; edit-tui/lang/c/api.rkt —— C 语言能力唯一对外面
;;;
;;; 语言层保持纯；插件只 require 这里，不直接 require 内部实现。

(require "../shared/edit.rkt"
         "base/file.rkt"
         "base/keywords.rkt"
         "base/indent.rkt"
         "base/lex.rkt"
         "color/highlight.rkt"
         "color/color.rkt"
         "completion/completion.rkt"
         "docs/docs.rkt"
         "data/lib.rkt")

(provide (all-from-out "../shared/edit.rkt")
         (all-from-out "base/file.rkt")
         (all-from-out "base/keywords.rkt")
         (all-from-out "base/indent.rkt")
         (all-from-out "base/lex.rkt")
         (all-from-out "color/highlight.rkt")
         (all-from-out "color/color.rkt")
         (all-from-out "completion/completion.rkt")
         (all-from-out "docs/docs.rkt")
         (all-from-out "data/lib.rkt"))

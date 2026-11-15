#lang racket

;;; edit-tui/lang/racket/base/edit.rkt —— 兼容入口
;;;
;;; line-edit / splice 等是语言无关的编辑描述，实现已移到 lang/shared/edit.rkt。
;;; 保留这个文件，避免 Racket 语言层和测试改 require 路径。

(require "../../shared/edit.rkt")

(provide (all-from-out "../../shared/edit.rkt"))

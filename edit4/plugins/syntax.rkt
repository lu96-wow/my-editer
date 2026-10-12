#lang racket

;;; edit4/plugins/syntax.rkt —— 语法高亮（关键字/字符串/注释/数字）插件包
;;;
;;; 纯 decor：直接用 decor/syntax.rkt 的函数。

(provide syntax-plugin)

(require "../plugin.rkt" "../decor/syntax.rkt")

(define syntax-plugin
  (make-plugin #:name 'syntax #:decor (list syntax-decor)))

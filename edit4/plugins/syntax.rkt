#lang racket

;;; edit4/plugins/syntax.rkt —— 语法高亮（关键字/字符串/注释/数字）插件包
;;;
;;; 纯 decor；只对 Racket 源文件生效（#:applies?），算法本身不含类型判断。

(provide syntax-plugin)

(require "../plugin.rkt" "../decor/syntax.rkt" "../decor/kind.rkt")

(define syntax-plugin
  (make-plugin #:name 'syntax
               #:applies? racket-file?
               #:decor (list syntax-decor)))

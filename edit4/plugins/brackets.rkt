#lang racket

;;; edit4/plugins/brackets.rkt —— 括号嵌套深度背景插件包
;;;
;;; 纯 decor；只对 Racket 源文件生效（#:applies?）。

(provide bracket-depth-plugin)

(require "../plugin.rkt" "../decor/bracket-depth.rkt" "../decor/kind.rkt")

(define bracket-depth-plugin
  (make-plugin #:name 'brackets
               #:applies? racket-file?
               #:decor (list bracket-depth-decor)))

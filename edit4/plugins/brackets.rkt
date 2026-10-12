#lang racket

;;; edit4/plugins/brackets.rkt —— 括号高亮（嵌套深度底色 + 光标配对）插件包
;;;
;;; 纯 decor；只对 Racket 源文件生效（#:applies?）。

(provide bracket-plugin)

(require "../plugin.rkt" "../decor/bracket.rkt" "../decor/kind.rkt")

(define bracket-plugin
  (make-plugin #:name 'brackets
               #:applies? racket-file?
               #:decor (list bracket-decor)))

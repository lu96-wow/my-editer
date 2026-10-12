#lang racket

;;; edit4/plugins/brackets.rkt —— 括号高亮（嵌套深度底色 + 光标配对）插件包

(provide bracket-plugin)

(require "../plugin.rkt" "../decor/bracket.rkt")

(define bracket-plugin
  (make-plugin #:name 'brackets #:decor (list bracket-decor)))

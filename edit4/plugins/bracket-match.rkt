#lang racket

;;; edit4/plugins/bracket-match.rkt —— 光标在括号上时高亮配对括号插件包
;;;
;;; 纯 decor；对所有文件生效（不声明 #:applies?）。

(provide bracket-match-plugin)

(require "../plugin.rkt" "../decor/bracket-match.rkt")

(define bracket-match-plugin
  (make-plugin #:name 'bracket-match
               #:decor (list bracket-match-decor)))

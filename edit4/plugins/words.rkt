#lang racket

;;; edit4/plugins/words.rkt —— 光标当前词高亮插件包

(provide words-plugin)

(require "../plugin.rkt" "../decor/words.rkt")

(define words-plugin
  (make-plugin #:name 'words #:decor (list words-decor)))

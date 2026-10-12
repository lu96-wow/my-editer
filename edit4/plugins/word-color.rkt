#lang racket

;;; edit4/plugins/word-color.rkt —— 同词着色插件包（参考 edit1）
;;;
;;; 纯 decor；只对 Racket 源文件生效（#:applies?）。
;;; 「色 = 词名的稳定散列」在 decor/word-color.rkt，算法本身不含类型判断。

(provide word-color-plugin)

(require "../plugin.rkt" "../decor/word-color.rkt" "../decor/kind.rkt")

(define word-color-plugin
  (make-plugin #:name 'word-color
               #:applies? racket-file?
               #:decor (list word-color-decor)))

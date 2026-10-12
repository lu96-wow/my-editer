#lang racket

;;; edit4/plugins/words.rkt —— 光标当前词高亮插件包
;;;
;;; 对所有文件生效（不声明 #:applies?）。

(provide words-plugin)

(require "../plugin.rkt" "../decor/words.rkt" "../decor/protocol.rkt")

(define words-plugin
  (make-plugin #:name 'words #:decor (list (pure-decor words-decor))))

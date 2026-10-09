#lang racket

;;; edit/core/file-kind.rkt —— 文档类型判定（纯）
;;;
;;; 「哪些文件算 Racket 源文件」的单一来源：高亮 / 将来缩进 / 补全共用。按扩展名判断。

(require racket/path)

(provide racket-exts racket-file? racket-applies?)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path (if (member (path-get-extension path) racket-exts) #t #f)))

;; 插件协议 (path text) -> bool；按扩展名判断只需 path。
(define (racket-applies? path text) (racket-file? path))

#lang racket

;;; edit3/kind.rkt —— 文档类型判定（纯）
;;; 「哪些文件算 Racket 源文件」的单一来源（高亮等共用）。

(provide racket-exts racket-file? racket-applies?)

(require racket/path)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path (if (member (path-get-extension path) racket-exts) #t #f)))

;; 插件协议 (path text) -> bool
(define (racket-applies? path _text) (racket-file? path))

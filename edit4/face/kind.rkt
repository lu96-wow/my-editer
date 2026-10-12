#lang racket

;;; edit4/face/kind.rkt —— 文档类型判定（纯）

(provide racket-exts racket-file? racket-applies?)

(require racket/path)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path (if (member (path-get-extension path) racket-exts) #t #f)))

(define (racket-applies? path _text) (racket-file? path))

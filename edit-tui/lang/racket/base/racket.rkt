#lang racket

;;; edit-tui/lang/racket/racket.rkt —— Racket 文档类型判定（纯）

(provide racket-exts racket-file? racket-text?)

(require racket/path
         racket/string)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path
       (let ([p (if (string? path) (string->path path) path)])
         (and (member (path-get-extension p) racket-exts) #t))))

(define (racket-text? text)
  (and (string? text)
       (regexp-match? #rx"^[ \t]*#lang[ \t]+racket" text)))

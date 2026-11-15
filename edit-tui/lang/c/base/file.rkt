#lang racket

;;; edit-tui/lang/c/base/file.rkt —— C 文件识别（纯）

(require racket/path
         racket/string)

(provide c-file?
         c-text?
         c-source?)

(define c-exts '(#".c" #".h" #".i"))

(define (c-file? path)
  (and path
       (let ([ext (path-get-extension
                   (if (path? path) path (string->path path)))])
         (and ext (member ext c-exts) #t))))

;; 无 path 的临时 buffer：出现 #include / 常见 C 形态时按 C 处理。
(define (c-text? text)
  (and (string? text)
       (regexp-match? #rx"^[ \t]*#[ \t]*(include|define|ifndef|pragma)" text)))

(define (c-source? path text)
  (or (c-file? path)
      (and (not path) (c-text? text))))

#lang racket

;;; edit-tui-rebuild/config/keymap/buffer.rkt —— buffer 创建时的键表匹配
;;;
;;; 只匹配键表，不匹配 analyzer / hook。
;;; buffer-key-table 是必需参数：path/text -> command-table。
;;; 目前 Racket 与普通文本都用 edit-command-table；以后加语言键只改这里。

(require racket/path
         racket/string
         "default.rkt")

(provide buffer-key-table
         racket-buffer-key-table
         text-buffer-key-table)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-buffer? path text)
  (or (and path
           (member (path-get-extension (if (path? path) path (string->path path)))
                   racket-exts)
           #t)
      (and text
           (regexp-match? #rx"^[ \t]*#lang[ \t]+racket" text))))

(define racket-buffer-key-table edit-command-table)
(define text-buffer-key-table edit-command-table)

(define (buffer-key-table path text)
  (if (racket-buffer? path text)
      racket-buffer-key-table
      text-buffer-key-table))

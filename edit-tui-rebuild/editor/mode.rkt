#lang racket

;;; edit-tui-rebuild/editor/mode.rkt —— buffer mode（最小版）
;;;
;;; 对齐旧 buffer-mode-for-creation 的语言选择：
;;;   .rkt/.rktl/.rktd/.scrbl -> racket
;;;   无 path 且文本首行是 #lang racket -> racket
;;;   其他 -> text
;;;
;;; 这里只决定语言插件（pair / indent / docs）的行为；键表 / 解析环境还没搬。

(require racket/path
         racket/string)

(provide doc-mode-for)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path
       (let ([ext (path-get-extension
                   (if (path? path) path (string->path path)))])
         (and ext (member ext racket-exts) #t))))

(define (racket-text? text)
  (and (string? text)
       (regexp-match? #rx"^[ \t]*#lang[ \t]+racket" text)))

(define (doc-mode-for path text)
  (cond
    [(racket-file? path) 'racket]
    [(and (not path) (racket-text? text)) 'racket]
    [else 'text]))

#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯：doc-meta -> bool）
;;;
;;; kind.rkt —— 高亮插件的适用范围判断（共享一份，避免三个 decor 各写一遍）。

(provide racket-path? racket-doc-meta?)

(require racket/path
         "../../model/workspace.rkt")

(define racket-extensions '("rkt" "rktl" "rktd" "scratch"))

(define (racket-path? path)
  (and path
       (let ([e (filename-extension path)])
         (and e (for/or ([ext (in-list racket-extensions)])
                  (string=? ext (string-downcase (bytes->string/utf-8 e))))))))

(define (racket-doc-meta? dm)
  (and dm
       (not (doc-meta-internal? dm))
       (or (eq? (doc-meta-mode dm) 'racket)
           (racket-path? (doc-meta-path dm)))))

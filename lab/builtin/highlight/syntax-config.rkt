#lang racket

;;; lab-rebuild/config/syntax.rkt —— 语法高亮可配置表（纯数据）
;;;
;;; 关键字顺序 = 取色顺序：想给某个关键字换色，挪它的位置即可。
;;; 扩展名决定哪些文件参与关键字高亮。

(provide keyword-list racket-exts racket-file?)

(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path (member (path-get-extension path) racket-exts)))

(define keyword-list
  '("define" "define-values" "define-syntax" "define-struct"
    "lambda" "λ"
    "let" "let*" "letrec" "let-values" "let*-values" "letrec-values"
    "if" "cond" "case" "when" "unless" "begin" "and" "or" "not"
    "require" "provide" "module" "module*" "struct" "struct*"
    "match" "match*" "match-lambda"
    "for" "for/list" "for/fold" "for/and" "for/or" "for/vector"
    "set!" "quote" "quasiquote" "unquote" "unquote-splicing"
    "with-handlers" "parameterize" "else" "syntax-rules"))

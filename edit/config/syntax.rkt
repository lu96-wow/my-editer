#lang racket

;;; edit/config/syntax.rkt —— 语法高亮关键字表（纯数据）
;;;
;;; 关键字顺序 = 取色顺序：想给某个关键字换色，挪它的位置即可。
;;; 「哪些文件参与」由插件的 applies?（core/file-kind.rkt）决定。

(provide keyword-list)

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

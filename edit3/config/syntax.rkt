#lang racket

;;; edit3/config/syntax.rkt —— 关键字语义分组（纯数据）
;;; 同组同色；分组顺序对应命名 face（见 config/theme.rkt）。

(provide keyword-category-order keyword-categories)

(define keyword-category-order '(def control macro binding module))

(define keyword-categories
  (hash
   "define" 'def "define-values" 'def "define-struct" 'def
   "struct" 'def "struct*" 'def "set!" 'def
   "if" 'control "cond" 'control "case" 'control "when" 'control "unless" 'control
   "and" 'control "or" 'control "not" 'control "begin" 'control
   "match" 'control "match*" 'control "match-lambda" 'control
   "for" 'control "for/list" 'control "for/fold" 'control
   "for/and" 'control "for/or" 'control "for/vector" 'control "with-handlers" 'control
   "define-syntax" 'macro "define-syntax-rule" 'macro "syntax-rules" 'macro
   "lambda" 'binding "λ" 'binding
   "let" 'binding "let*" 'binding "letrec" 'binding
   "let-values" 'binding "let*-values" 'binding "letrec-values" 'binding "parameterize" 'binding
   "require" 'module "provide" 'module "module" 'module "module*" 'module
   "quote" 'module "quasiquote" 'module "unquote" 'module "unquote-splicing" 'module
   "else" 'module))

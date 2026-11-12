#lang racket

;;; edit-tui/lang/racket/keywords.rkt —— Racket 关键字语义分组（纯数据）
;;;
;;; 同组同色；这个分组只属于 Racket 语言层，主题负责把组映射到实际颜色。
;;; 补全也会把关键字作为本地候选的一部分。

(provide keyword-category-order
         keyword-categories
         keyword-category
         keyword?)
(require racket/string)

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

(define (keyword-category word)
  (hash-ref keyword-categories word #f))

(define (keyword? word)
  (and (keyword-category word) #t))

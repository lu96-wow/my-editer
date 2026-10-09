#lang racket

;;; edit/config/syntax.rkt —— 关键字语义分组（纯数据）
;;;
;;; 关键字按语义分组；**同组同色**（不再是每个关键字一色）。
;;; 分组顺序 = 主题 'keyword 色板的取色顺序。想给某关键字换组改这里；
;;; 想整体换色改主题方案（theme/schemes/*.rkt，选哪套见 config/theme.rkt）。

(provide keyword-category-order keyword-categories)

(define keyword-category-order '(def control macro binding module))

(define keyword-categories
  (hash
   ;; 定义 / 赋值
   "define" 'def "define-values" 'def "define-struct" 'def
   "struct" 'def "struct*" 'def "set!" 'def
   ;; 控制 / 条件
   "if" 'control "cond" 'control "case" 'control "when" 'control "unless" 'control
   "and" 'control "or" 'control "not" 'control "begin" 'control
   "match" 'control "match*" 'control "match-lambda" 'control
   "for" 'control "for/list" 'control "for/fold" 'control
   "for/and" 'control "for/or" 'control "for/vector" 'control
   "with-handlers" 'control
   ;; 宏
   "define-syntax" 'macro "define-syntax-rule" 'macro "syntax-rules" 'macro
   ;; 绑定 / 函数
   "lambda" 'binding "λ" 'binding
   "let" 'binding "let*" 'binding "letrec" 'binding
   "let-values" 'binding "let*-values" 'binding "letrec-values" 'binding
   "parameterize" 'binding
   ;; 模块 / 引用
   "require" 'module "provide" 'module "module" 'module "module*" 'module
   "quote" 'module "quasiquote" 'module "unquote" 'module "unquote-splicing" 'module
   "else" 'module))

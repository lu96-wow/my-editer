#lang racket

;;; edit/test/analysis-lexer-test.rkt —— 分析工具：词法（headless）
;;;
;;;   raco test edit/test/analysis-lexer-test.rkt

(require rackunit
         "../plugin/analysis/tools/span.rkt"
         "../plugin/analysis/tools/lexer.rkt")

(define (types s) (map token-type (lex-text s)))
(define (spans s) (map token-span (lex-text s)))

;;; ---------- 类型归一 ----------

(check-equal? (types "(define x 1)\n")
              '(open-paren symbol white-space symbol white-space constant close-paren white-space))
(check-equal? (types "[a]") '(open-paren symbol close-paren))
(check-equal? (types "{a}") '(open-paren symbol close-paren))

;; 注释 / 字符串 / 空白
(check-equal? (types "; hi\n") '(comment white-space))
(check-equal? (types "\"s\"") '(string))
(check-equal? (types "#| c |# 5") '(comment white-space constant))
(check-equal? (types "a b") '(symbol white-space symbol))

;; #lang / quote 家族 / sexp comment
(check-equal? (types "#lang racket\n") '(lang-directive white-space))
(check-equal? (types "'x") '(quote symbol))
(check-equal? (types "`x") '(quasiquote symbol))
(check-equal? (types ",x") '(unquote symbol))
(check-equal? (types ",@x") '(unquote-splicing symbol))
(check-equal? (types "#;x") '(sexp-comment symbol))
(check-equal? (types "#'x") '(syntax-quote symbol))
(check-equal? (types "#`x") '(syntax-quasiquote symbol))
(check-equal? (types "#,x") '(syntax-unquote symbol))
(check-equal? (types "#,@x") '(syntax-unquote-splicing symbol))

;;; ---------- 偏移（0-based，半开） ----------

(check-equal? (spans "(a)") (list (span 0 1) (span 1 2) (span 2 3)))
(check-equal? (spans "#lang racket\n") (list (span 0 12) (span 12 13)))
(check-equal? (spans "ab cd")
              (list (span 0 2) (span 2 3) (span 3 5)))

;; 每个 span 不越界，且按起点递增
(for ([s (in-list (list "(a)\n" "#lang racket\n(define x 1)\n" "中 文"))])
  (define toks (lex-text s))
  (for ([tk (in-list toks)])
    (define sp (token-span tk))
    (check-true (<= 0 (span-start sp) (span-end sp) (string-length s)))))

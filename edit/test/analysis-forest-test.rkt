#lang racket

;;; edit/test/analysis-forest-test.rkt —— 分析工具：token forest（headless）
;;;
;;;   raco test edit/test/analysis-forest-test.rkt

(require rackunit
         "../plugin/analysis/tools/span.rkt"
         "../plugin/analysis/tools/lexer.rkt"
         "../plugin/analysis/tools/forest.rkt")

(define (forest-of s) (build-forest (lex-text s)))
(define (gopen g) (span-start (token-span (group-open g))))

;; "(define (f x) (+ x 1))\n"
;;  0:( 1:define 8:( 9:f 11:x 12:) 14:( 15:+ 17:x 19:1 20:) 21:)
(define t1 "(define (f x) (+ x 1))\n")
(define f1 (forest-of t1))

(check-equal? (forest-form-head f1 1) (span 1 7))       ; 外层的 define
(check-equal? (gopen (forest-enclosing-group f1 11)) 8) ; x 在最内层 (f x)
(check-equal? (forest-form-head f1 11) (span 9 10))     ; (f x) 的 f
(check-equal? (forest-form-head f1 15) (span 15 16))    ; (+ x 1) 的 +
(check-false (forest-form-head f1 0))                   ; 开括号本身不算体内

;; 注释 / 白空格不算 form head
(check-equal? (forest-form-head (forest-of "( ; c\n foo)") 8) (span 7 10))  ; foo @7

;; quote 前缀：不产生 group
(define fq (forest-of "'x"))
(check-false (forest-enclosing-group fq 1))
(check-false (forest-form-head fq 1))

;; 括号不平衡不崩：close = #f
(define fu (forest-of "(a"))
(define gu (forest-enclosing-group fu 1))
(check-not-false gu)
(check-false (group-close gu))

;; 顶层多个 form
(define fm (forest-of "(a) (b)\n"))
(check-equal? (gopen (forest-enclosing-group fm 1)) 0)
(check-equal? (gopen (forest-enclosing-group fm 5)) 4)

;; sexp-comment 区间（含被注释的整个 (a)）
(check-equal? (forest-sexp-comment-spans (forest-of "#;(a) b\n"))
              (list (span 0 5)))
(check-equal? (forest-sexp-comment-spans (forest-of "x ; not a comment\n"))
              '())

;; 嵌套 #; 不重复计（外层 #; 覆盖内层及其操作数）
(check-equal? (forest-sexp-comment-spans (forest-of "#;#;a b\n"))
              (list (span 0 7)))

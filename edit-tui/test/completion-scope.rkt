#lang racket

;;; 补全作用域：
;;;   · 模块级 define 全 buffer 可见
;;;   · 局部绑定 / 本地词只来自当前顶层表单
;;;   · require 增删会改变候选

(require rackunit
         racket/file
         racket/path
         racket/string
         "../compat/lang/racket/api.rkt")

(define text
  (string-append
   "#lang racket\n"
   "\n"
   "(define (alpha xs)\n"
   "  (define secret-alpha 1)\n"
   "  secret-alpha)\n"
   "\n"
   "(define (beta ys)\n"
   "  (define secret-beta 2)\n"
   "  be se)\n"))

(define cands (completion-at #f text 8 4))
(check-true (and (member "beta" cands) #t))
(check-false (member "secret-alpha" cands))
(check-false (member "xs" cands))

(define scoped-cands (completion-at #f text 8 7))
(check-true (and (member "secret-beta" scoped-cands) #t))
(check-false (member "secret-alpha" scoped-cands))
(check-false (member "xs" scoped-cands))

;;; require 增删影响导出名候选

(define root (make-temporary-directory))
(define dep-path (build-path root "dep.rkt"))
(display-to-file "#lang racket\n(provide dep-name)\n" dep-path #:exists 'replace)
(define main-path (path->string (build-path root "main.rkt")))
(define dep-key (path->string (simplify-path dep-path)))
(define open (hash dep-key "#lang racket\n(provide dep-name)\n(define inside-dep 1)\n"))

(define with-require
  (string-append "(require \"dep.rkt\")\n"
                 "(define x de)\n"))
(define without-require
  (string-append "(define x de)\n"))

(define with-cands
  (completion-at main-path with-require 1 12 #:open open))
(check-true (and (member "dep-name" with-cands) #t))

(define without-cands
  (completion-at main-path without-require 0 12 #:open open))
(check-false (member "dep-name" without-cands))

(delete-directory/files root)
(displayln "edit-tui/test/completion-scope.rkt: ok")

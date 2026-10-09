#lang racket

;;; edit/test/highlight-incremental-test.rkt —— 高亮插件契约（headless）
;;;
;;;   raco test edit/test/highlight-incremental-test.rkt
;;;
;;; 覆盖：open/change 产出整篇 fills；词表状态跨次累积；活动词跳过。

(require rackunit
         "../plugin/registry.rkt"
         "../plugin/builtin/syntax.rkt"
         "../plugin/builtin/words.rkt"
         "../core/face.rkt")

(define syntax-change (doc-plugin-change syntax-plugin))
(define word-change (doc-plugin-change word-plugin))

(define (cctx lines active)
  (change-ctx '() active (list->vector lines) "test.rkt"))

;; syntax：整篇扫描命中 "let"
(define-values (_st sf) (syntax-change #f (cctx (list "let x 1") #f)))
(check-true (pair? sf))
(check-equal? (palette-color-kind (list-ref (car sf) 4)) 'keyword)

;; words：表累积（旧词沿用、新词补号）
(define-values (st1 f1) (word-change #f (cctx (list "alpha beta") #f)))
(check-true (pair? f1))
(define alpha0 (hash-ref st1 "alpha"))

(define-values (st2 f2) (word-change st1 (cctx (list "alpha beta" "gamma alpha") #f)))
(check-true (pair? f2))
(check-equal? (hash-ref st2 "alpha") alpha0)                  ; 旧词沿用同号
(check-equal? (hash-ref st2 "gamma" #f) 2)                    ; 新词补号（= 旧表词数）
(check-equal? (hash-ref st2 "beta") (hash-ref st1 "beta"))    ; 未变词仍在表里

;; 活动词跳过：line 0 起点 0 的 "alpha" 不在 fills 里
(define-values (_st3 f3) (word-change st1 (cctx (list "alpha beta") (list 0 0 5))))
(check-true (for/and ([f (in-list f3)]) (not (and (= (car f) 0) (= (cadr f) 0)))))

#lang racket

;;; edit/test/highlight-incremental-test.rkt —— 高亮插件增量契约（headless）
;;;
;;;   raco test edit/test/highlight-incremental-test.rkt
;;;
;;; 覆盖：change 只声明脏行 touched、只产出脏行 fills；词表状态跨次累积。

(require rackunit
         "../plugin/registry.rkt"
         "../plugin/builtin/syntax.rkt"
         "../plugin/builtin/words.rkt"
         "../core/face.rkt")

(define syntax-change (doc-plugin-change syntax-plugin))
(define word-change (doc-plugin-change word-plugin))

;; 测试用最小 change-ctx（line-ref / line-count 这两插件用不到）。
(define (cctx dirty active)
  (change-ctx dirty '() active (lambda (_n) "") 0 "test.rkt"))

;; syntax：touched = 脏行，且命中关键字 "let"
(define-values (_st touched sf)
  (syntax-change #f (cctx (list (cons 1 "let x 1")) #f)))
(check-true (pair? sf))
(check-equal? touched '(1))
(check-true (for/and ([f (in-list sf)]) (= (car f) 1)))
(check-equal? (palette-color-kind (list-ref (car sf) 4)) 'keyword)

;; words：touched 限定 + 状态累积
(define-values (st1 touched1 f1)
  (word-change #f (cctx (list (cons 0 "alpha beta")) #f)))
(check-equal? touched1 '(0))
(check-true (for/and ([f (in-list f1)]) (= (car f) 0)))
(define alpha0 (hash-ref st1 "alpha"))

(define-values (st2 touched2 f2)
  (word-change st1 (cctx (list (cons 1 "gamma alpha")) #f)))
(check-equal? touched2 '(1))
(check-true (for/and ([f (in-list f2)]) (= (car f) 1)))      ; 只第 1 行
(check-equal? (hash-ref st2 "alpha") alpha0)                  ; 旧词沿用同号
(check-equal? (hash-ref st2 "gamma" #f) 2)                    ; 新词补号（= 旧表词数）
(check-equal? (hash-ref st2 "beta") (hash-ref st1 "beta"))    ; 未动行仍在表里

;; 活动词跳过：脏行里活动词不上色
(define-values (_st3 _touched3 f3)
  (word-change st1 (cctx (list (cons 0 "alpha beta")) (list 0 0 5))))
(check-true (for/and ([f (in-list f3)]) (not (= (cadr f) 0))))  ; 不像 alpha（起点 0）

#lang racket

;;; edit-rebuild/test/route-test.rkt —— 路由命中 / 排序 / 作用域 / 前缀（纯）

(require rackunit
         "../core/key.rkt"
         "../core/scope.rkt"
         "../core/route.rkt")

(define ctx
  (context 'editor #f 'editor
           (hash 'docs #t)
           (hash 'interaction 'docs)
           #f))

(define r-low  (route* (key 'x) '(low)  #:priority 0))
(define r-high (route* (key 'x) '(high) #:priority 10))
(define r-docs (route* (key 'x) '(docs) #:when (scope-visible 'docs) #:priority 5))
(define r-none (route* (key 'x) '(none) #:when (scope-visible 'nope) #:priority 99))
(define r-pfx  (route* (key 'd) '(pfx) #:prefix 'C-p))

(define rss (list r-low r-docs r-high r-none))

;; priority 降序；scope 不命中的被过滤。
(check-equal? (resolve rss ctx (key 'x)) (list r-high r-docs r-low))

;; 未命中 → '()
(check-equal? (resolve rss ctx (key 'y)) '())

;; 前缀：顶层 context（prefix #f）不命中 r-pfx；前缀激活后只命中同前缀。
(check-equal? (resolve (list r-pfx) ctx (key 'd)) '())
(define pctx (context 'editor #f 'editor (hash) (hash) 'C-p))
(check-equal? (resolve (list r-pfx) pctx (key 'd)) (list r-pfx))

;; priority 相同 → 保持声明顺序（稳定）
(define a (route* (key 'z) '(a)))
(define b (route* (key 'z) '(b)))
(check-equal? (resolve (list a b) ctx (key 'z)) (list a b))

;; 组合子
(check-equal? (route-list-merge (list a) (list b)) (list a b))
(check-equal? (route-list-add (list a) b) (list b a))

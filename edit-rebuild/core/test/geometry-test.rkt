#lang racket

;;; edit-rebuild/core/test/geometry-test.rkt —— 布局求值缓存（纯）
;;;
;;;   raco test edit-rebuild/core/test/geometry-test.rkt

(require rackunit
         "../geometry/place.rkt")

(define calls (box 0))
(define (compute) (set-box! calls (add1 (unbox calls))) '(a b))

;; 首次：算
(define c1 (place-cache-refresh #f '(tree vis 80 24) compute))
(check-equal? (unbox calls) 1)
(check-equal? (place-cache-placed c1) '(a b))

;; 同键：复用，不重算
(define c2 (place-cache-refresh c1 '(tree vis 80 24) compute))
(check-eq? c1 c2)
(check-equal? (unbox calls) 1)

;; 换键：重算
(define c3 (place-cache-refresh c2 '(tree vis 80 25) compute))
(check-equal? (unbox calls) 2)

;; stale? 语义
(check-true (place-cache-stale? #f 'k))
(check-false (place-cache-stale? c3 '(tree vis 80 25)))
(check-true (place-cache-stale? c3 '(tree vis 80 24)))

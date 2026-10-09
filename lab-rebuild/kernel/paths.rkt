#lang racket

;;; lab-re-rebuild/kernel/paths.rkt —— did ↔ 规范化路径（双向）。

(require racket/path)

(provide (struct-out path-table)
         make-path-table path-table-add! path-table-remove!
         path-table-did path-table-path path-table-open? path-table-dids-under)

(struct path-table (by-did by-path) #:transparent)

(define (canonical p) (simplify-path (path->complete-path p)))
(define (make-path-table) (path-table (make-hash) (make-hash)))

(define (path-table-add! t did p)
  (define np (canonical p))
  (hash-set! (path-table-by-did t) did np)
  (hash-set! (path-table-by-path t) np did))

(define (path-table-remove! t did)
  (define p (hash-ref (path-table-by-did t) did #f))
  (when p (hash-remove! (path-table-by-path t) p))
  (hash-remove! (path-table-by-did t) did))

(define (path-table-did t p) (hash-ref (path-table-by-path t) (canonical p) #f))
(define (path-table-path t did) (hash-ref (path-table-by-did t) did #f))
(define (path-table-open? t p) (and (path-table-did t p) #t))

(define (path-under? base p)
  (define b (explode-path (simplify-path base)))
  (define q (explode-path (simplify-path p)))
  (and (>= (length q) (length b)) (equal? b (take q (length b)))))

(define (path-table-dids-under t dir)
  (define np (canonical dir))
  (for/list ([(did p) (in-hash (path-table-by-did t))] #:when (path-under? np p)) did))

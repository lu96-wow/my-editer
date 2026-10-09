#lang racket

;;; edit/core/file-map.rkt —— document <-> file-path 映射（纯）
;;;
;;; did -> path 与 path -> did 双向；path 规范化（complete + simplify）后做键。
;;; 只做映射，不做 I/O；打开 / 保存 / 去重 / 删目录 由 document 层使用。

(require racket/path)

(provide (struct-out file-map)
         file-map-empty
         file-map-add file-map-remove
         file-map-path file-map-did
         file-map-dids file-map-dids-under)

(struct file-map (did->path path->did) #:transparent)
;; did->path : (hash did -> path)
;; path->did : (hash path -> did)

(define (norm p) (simplify-path (path->complete-path p)))

(define (file-map-empty) (file-map (hash) (hash)))

;; 登记 did -> path；若该 path 已属别的 did，先解除那一个。
(define (file-map-add fm did path)
  (define np (norm path))
  (define old (hash-ref (file-map-path->did fm) np #f))
  (define fm1 (if (and old (not (equal? old did))) (file-map-remove fm old) fm))
  (file-map (hash-set (file-map-did->path fm1) did np)
            (hash-set (file-map-path->did fm1) np did)))

(define (file-map-remove fm did)
  (define p (hash-ref (file-map-did->path fm) did #f))
  (file-map (hash-remove (file-map-did->path fm) did)
            (if p (hash-remove (file-map-path->did fm) p) (file-map-path->did fm))))

(define (file-map-path fm did) (hash-ref (file-map-did->path fm) did #f))
(define (file-map-did fm path) (hash-ref (file-map-path->did fm) (norm path) #f))
(define (file-map-dids fm) (for/list ([(d p) (in-hash (file-map-did->path fm))]) d))

;; dir 目录下的 did（删目录用）。
(define (file-map-dids-under fm dir)
  (define nd (path->string (norm dir)))
  (define (under? p)
    (define s (path->string (norm p)))
    (and (>= (string-length s) (string-length nd))
         (string=? nd (substring s 0 (string-length nd)))))
  (for/list ([(d p) (in-hash (file-map-did->path fm))] #:when (under? p)) d))

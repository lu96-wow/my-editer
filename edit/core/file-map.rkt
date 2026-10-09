#lang racket

;;; edit/core/file-map.rkt —— document <-> file-path 映射（纯）
;;;
;;; did -> path 与 path -> did 双向；path 规范化（complete + simplify）后做键。
;;; 只做映射，不做 I/O；打开 / 保存 / 去重 / 删目录 由 document 层使用。

(require racket/path
         "path.rkt")

(provide (struct-out file-map)
         file-map-empty
         file-map-add file-map-remove
         file-map-path file-map-did
         file-map-dids)

(struct file-map (did->path path->did) #:transparent)
;; did->path : (hash did -> path)
;; path->did : (hash path -> did)


(define (file-map-empty) (file-map (hash) (hash)))

;; 登记 did -> path；若该 path 已属别的 did，先解除那一个。
(define (file-map-add fm did path)
  (define np (normalize path))
  (define old (hash-ref (file-map-path->did fm) np #f))
  (define fm1 (if (and old (not (equal? old did))) (file-map-remove fm old) fm))
  (file-map (hash-set (file-map-did->path fm1) did np)
            (hash-set (file-map-path->did fm1) np did)))

(define (file-map-remove fm did)
  (define p (hash-ref (file-map-did->path fm) did #f))
  (file-map (hash-remove (file-map-did->path fm) did)
            (if p (hash-remove (file-map-path->did fm) p) (file-map-path->did fm))))

(define (file-map-path fm did) (hash-ref (file-map-did->path fm) did #f))
(define (file-map-did fm path) (hash-ref (file-map-path->did fm) (normalize path) #f))
(define (file-map-dids fm) (for/list ([(d p) (in-hash (file-map-did->path fm))]) d))


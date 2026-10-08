#lang racket

;;; lab-rebuild/builtin/document-api.rkt —— 文档元数据（did ↔ 路径、脏）的**读写接口**。
;;;
;;; service 'document = (list path-table dirty-hash)。
;;; 实现写这里；status 等只读查询也走这里 —— 于是调用方不 require document 的实现。

(require "../kernel/api.rkt")

(provide doc-init!
         doc-did-for-path doc-path doc-open?
         doc-set-path! doc-remove! doc-dids-under
         doc-dirty? doc-mark-dirty! doc-clear-dirty!)

(define (doc-state ctx) (service-ref ctx 'document))
(define (pt ctx) (car (doc-state ctx)))
(define (dirty ctx) (cadr (doc-state ctx)))

(define (doc-init! ctx)
  (service-put ctx 'document (list (make-path-table) (make-hash))))

(define (doc-did-for-path ctx p) (path-table-did (pt ctx) p))
(define (doc-path ctx did) (path-table-path (pt ctx) did))
(define (doc-open? ctx p) (path-table-open? (pt ctx) p))
(define (doc-set-path! ctx did p) (path-table-add! (pt ctx) did p))
(define (doc-remove! ctx did)
  (path-table-remove! (pt ctx) did)
  (hash-remove! (dirty ctx) did))
(define (doc-dids-under ctx p) (path-table-dids-under (pt ctx) p))

(define (doc-dirty? ctx did) (and (hash-ref (dirty ctx) did #f) #t))
(define (doc-mark-dirty! ctx did) (hash-set! (dirty ctx) did #t))
(define (doc-clear-dirty! ctx did) (hash-remove! (dirty ctx) did))

#lang racket

;;; edit4/plugins/sync/mapping.rkt —— 纯：mapping 数据访问 + 方向词表

(provide mapping-by-id mapping-terms mapping-langs dir-table mapped-term? detect-direction)

(require racket/list racket/string "../../config/sync.rkt")

(define (mapping-by-id id)
  (for/first ([m (in-list sync-mappings)] #:when (eq? id (car m))) m))

(define (mapping-langs m) (list (cadr m) (caddr m)))
(define (mapping-terms m) (list-ref m 3))

;; direction 'a->b | 'b->a -> alist from-term -> to-term
(define (dir-table m dir)
  (if (eq? dir 'a->b)
      (mapping-terms m)
      (for/list ([p (in-list (mapping-terms m))]) (cons (cdr p) (car p)))))

;; 该词是否出现在任一词表（两个方向都算）——高亮用。
(define (mapped-term? tok)
  (for/or ([m (in-list sync-mappings)])
    (for/or ([p (in-list (mapping-terms m))])
      (or (equal? tok (car p)) (equal? tok (cdr p))))))

;; 文本里出现了 b 侧词（中文）→ 源是 b 侧，方向 b->a；否则 a->b。
(define (detect-direction m text)
  (if (for/or ([p (in-list (mapping-terms m))]) (string-contains? text (cdr p)))
      'b->a
      'a->b))

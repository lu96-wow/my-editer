#lang racket

;;; lab-rebuild/kernel/table.rkt —— 键表（纯）。

(require "binding.rkt")

(provide (struct-out keytable) kbd keytable-lookup keytable-merge)

(struct keytable (bindings) #:transparent)
;; bindings : hash(binding -> spec)；spec = command-name | (command-name . args)

;; 便捷构造： (kbd (key 'a 'ctrl) 'undo …)
(define (kbd . kvs)
  (unless (even? (length kvs)) (error 'kbd "参数要成对"))
  (keytable (for/hash ([i (in-range 0 (length kvs) 2)])
              (values (list-ref kvs i) (list-ref kvs (add1 i))))))

(define (keytable-lookup t b)
  (and t b (hash-ref (keytable-bindings t) b #f)))

;; 合并：后面的覆盖前面的。
(define (keytable-merge ts)
  (keytable
   (for/fold ([h (hash)]) ([t (in-list ts)])
     (for/fold ([h h]) ([(b s) (in-hash (keytable-bindings t))])
       (hash-set h b s)))))

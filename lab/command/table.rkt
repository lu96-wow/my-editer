#lang racket

;;; lab/command/table.rkt —— 命令表：binding → command
;;;
;;; 不可变；`table-merge` 做覆盖（over 优先于 base），用于「每文档表 ⊕ 默认表」。

(require racket/hash
         "base.rkt")

(provide
 (struct-out table)
 make-table
 table-bindings
 table-lookup
 table-add
 table-merge)

(struct table (bindings) #:transparent)
;; bindings : hash binding -> command

(define (make-table [pairs '()])
  (table (for/hash ([p (in-list pairs)]) (values (car p) (cdr p)))))

;; pairs : (listof (cons binding command))
(define (table-lookup t b)
  (and t (hash-ref (table-bindings t) b #f)))

(define (table-add t b c)
  (table (hash-set (table-bindings t) b c)))

;; over 覆盖 base（同名 binding 用 over 的）。
(define (table-merge base over)
  (table (hash-union (table-bindings over) (table-bindings base)
                     #:combine (lambda (a b) a))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit
           "../input.rkt")

  (define m0 (modifiers #f #f #f #f))
  (define b-left (binding 'left m0))
  (define c1 (command 'one void))
  (define c2 (command 'two void))
  (define t1 (make-table (list (cons b-left c1))))
  (check-equal? (command-name (table-lookup t1 b-left)) 'one)
  (check-false (table-lookup t1 (binding 'right m0)))
  (define t2 (table-add t1 b-left c2))
  (check-equal? (command-name (table-lookup t2 b-left)) 'two)   ; 原表不变
  (check-equal? (command-name (table-lookup t1 b-left)) 'one)
  (define merged (table-merge t1 (make-table (list (cons b-left c2)))))
  (check-equal? (command-name (table-lookup merged b-left)) 'two)

  (displayln "lab/command/table.rkt: all tests passed"))

#lang racket

;;; lab/command/table.rkt —— 命令层基础类型 + 命令表
;;;
;;;   binding  绑定键：物理键名 + 修饰键（鼠标/滚轮不进表，由派发层通用处理）
;;;   command  命令：名字 + 过程 (session × ctx × input → (values session effects))
;;;   context  派发上下文：当前屏幕格数（鼠标命中、翻页等用）
;;;   table    binding → command（不可变；table-merge 做覆盖）

(require racket/hash
         "../protocol.rkt")

(provide
 (struct-out binding)
 (struct-out command)
 (struct-out context)
 make-command
 input->binding
 (struct-out table)
 make-table
 table-bindings
 table-lookup
 table-add
 table-merge)

;; 绑定键：name 是 char 或命名键 symbol；mods 是 modifiers。
(struct binding (name mods) #:transparent)

;; 派发上下文。
(struct context (rows cols) #:transparent)

;; 命令：proc : session ctx input -> (values session (listof effect))
(struct command (name proc) #:transparent)

(define (make-command name proc) (command name proc))

;; input → binding（只有 key 进表；其余 → #f，交给派发层的通用处理）。
(define (input->binding in)
  (match in
    [(key name mods) (binding name mods)]
    [_ #f]))

;;; ---------- 命令表 ----------

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
  (require rackunit)

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

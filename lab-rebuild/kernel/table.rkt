#lang racket

;;; lab-rebuild/kernel/table.rkt —— 键表 + 文档命令集（纯）。

(require "binding.rkt")

(provide (struct-out keytable) kbd keytable-merge keytable-lookup table-char-lookup keytable-add
         (struct-out keybinding)
         (struct-out command-set) make-command-set
         command-set-tables command-set-add-doc command-set-add-global)

(struct keytable (bindings) #:transparent)
;; bindings : hash(binding -> spec)

;; 便捷构造： (kbd (key 'a 'ctrl) 'undo …)
(define (kbd . kvs)
  (unless (even? (length kvs)) (error 'kbd "参数要成对"))
  (keytable (for/hash ([i (in-range 0 (length kvs) 2)])
              (values (list-ref kvs i) (list-ref kvs (add1 i))))))

(define (keytable-merge ts)
  (keytable (for/fold ([h (hash)]) ([t (in-list ts)])
              (for ([(b s) (in-hash (keytable-bindings t))]) (hash-set h b s)))))

;; tables : 底在前、顶在后；后命中的覆盖。
(define (keytable-lookup tables b)
  (for/or ([t (in-list (reverse tables))])
    (hash-ref (keytable-bindings t) b #f)))

;; miss 时按字符本身再查一次（模态表可按字符绑，如 C-p 后的 d）。
(define (table-char-lookup tables ev)
  (define k (and (key-event? ev) (key-event-key ev)))
  (and (char? k) (keytable-lookup tables (key (char->key-symbol k)))))

(define (keytable-add t k spec)
  (keytable (hash-set (keytable-bindings t) k spec)))

;; 组装期绑定贡献：往命名表里补一个键（功能自带默认键位用）。
(struct keybinding (table key spec) #:transparent)

(struct command-set (global docs) #:transparent)
;; global : (listof keytable)
;; docs   : hash did -> (listof keytable)

(define (make-command-set [global '()]) (command-set global (hash)))
(define (command-set-tables cs did)
  (append (command-set-global cs) (hash-ref (command-set-docs cs) did '())))
(define (command-set-add-doc cs did ts)
  (command-set (command-set-global cs) (hash-set (command-set-docs cs) did ts)))
(define (command-set-add-global cs t)
  (command-set (append (command-set-global cs) (list t)) (command-set-docs cs)))

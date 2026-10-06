#lang racket

;;; lab-rebuild/kernel/registry.rkt —— 统一贡献注册表。
;;;
;;; 所有扩展点都是 contrib：kind 决定语义，name 唯一，priority 决定顺序。
;;; 取代旧 lab 的多个模块级可变全局（command / keymap / mode-type / overlay / panel / hooks）。

(provide (struct-out contrib)
         (struct-out registry)
         reg-empty reg-add reg-del reg-ref reg-has?
         reg-kind reg-fold)

(struct contrib (kind name priority value) #:transparent)
;; kind  : symbol
;; name  : symbol
;; value : 由 kind 决定的契约（见各组合子）

(struct registry (entries) #:transparent)
;; entries : hash (cons kind name) -> contrib

(define (reg-empty) (registry (hash)))

(define (reg-add r c)
  (registry (hash-set (registry-entries r)
                      (cons (contrib-kind c) (contrib-name c))
                      c)))

(define (reg-del r kind name)
  (registry (hash-remove (registry-entries r) (cons kind name))))

(define (reg-ref r kind name)
  (hash-ref (registry-entries r) (cons kind name) #f))

(define (reg-has? r kind name)
  (hash-has-key? (registry-entries r) (cons kind name)))

;; priority 降序，其次 name 升序（稳定、确定）。
(define (reg-kind r kind)
  (sort (for/list ([(k v) (in-hash (registry-entries r))] #:when (eq? (car k) kind)) v)
        (lambda (a b)
          (cond [(= (contrib-priority a) (contrib-priority b))
                 (string<? (symbol->string (contrib-name a))
                           (symbol->string (contrib-name b)))]
                [else (> (contrib-priority a) (contrib-priority b))]))))

(define (reg-fold r kind init f)
  (for/fold ([acc init]) ([c (in-list (reg-kind r kind))]) (f acc c)))

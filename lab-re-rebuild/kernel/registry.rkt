#lang racket

;;; lab-re-rebuild/kernel/registry.rkt —— 统一贡献注册表（命令 / 钩子 / 将来更多）。
;;;
;;; 所有扩展点都是 contrib：kind 决定语义，name 唯一。取代模块级可变全局。
;;; 目前只有 'command；编辑 / 焦点 / 命令三根柱子里，命令走这里。

(provide (struct-out contrib)
         (struct-out registry)
         reg-empty reg-add reg-del reg-ref reg-has? reg-kind)

(struct contrib (kind name value) #:transparent)

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

;; 同 kind 的贡献按 name 升序（确定性）。
(define (reg-kind r kind)
  (sort (for/list ([(k v) (in-hash (registry-entries r))] #:when (eq? (car k) kind)) v)
        (lambda (a b)
          (string<? (symbol->string (contrib-name a))
                    (symbol->string (contrib-name b))))))

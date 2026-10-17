#lang racket

;;; env/role.rkt —— 区域角色 → 行为（纯值）
;;;
;;; role 名是开放 symbol（'editor / 'panel / 'slot / 'tool …），实际行为由
;;; environment 的 roles 表查到。role 结构**不带名字**：表键就是名字，避免冗余。
;;;
;;;   splittable? : 能否被 split 原语切开
;;;   close-policy: 'hide | 'delete | 'keep-last | 'ignore
;;;   focusable?  : 能否成为 focus
;;;
;;; 未注册 role -> role-default（保守：不可切、只隐藏、不可聚焦）。

(provide (struct-out role)
         make-role
         role-default)

(struct role (splittable? close-policy focusable?) #:transparent)
;; splittable?  : bool
;; close-policy : 'hide | 'delete | 'keep-last | 'ignore
;; focusable?   : bool

(define (make-role #:splittable? [splittable? #f]
                   #:close [close-policy 'hide]
                   #:focusable? [focusable? #f])
  (unless (memq close-policy '(hide delete keep-last ignore))
    (error 'make-role "close-policy 要是 hide/delete/keep-last/ignore：~a" close-policy))
  (role splittable? close-policy focusable?))

(define role-default (make-role))

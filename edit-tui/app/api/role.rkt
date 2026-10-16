#lang racket

;;; api/role.rkt —— 公共 API 面：leaf 角色注册表
;;;
;;; 转发 app/role.rkt：define-role! / role-of / role-known?。此文件只转发，不放逻辑。

(require "../role.rkt")
(provide (all-from-out "../role.rkt"))

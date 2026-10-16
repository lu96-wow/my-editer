#lang racket

;;; api/doc-kind.rkt —— 公共 API 面：document 类型 → 命令表
;;;
;;; 转发 app/doc-kind.rkt：类型注册 + per-document 表层。此文件只转发，不放逻辑。

(require "../doc-kind.rkt")
(provide (all-from-out "../doc-kind.rkt"))

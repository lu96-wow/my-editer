#lang racket

;;; api/base-keys.rkt —— 公共 API 面：基础命令小表
;;;
;;; 转发 app/base-keys.rkt：edit-keys / motion-keys / pointer-keys / focus-keys。
;;; 此文件只转发，不放逻辑。

(require "../base-keys.rkt")
(provide (all-from-out "../base-keys.rkt"))

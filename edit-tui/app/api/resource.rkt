#lang racket

;;; api/resource.rkt —— 公共 API 面：资源（document / view）创建与装配
;;;
;;; 转发 app/resource.rkt：make-resources / open-document! / make-document / view-into。
;;; 内部登记函数不在公共面。此文件只转发，不放逻辑。

(require "../resource.rkt")
(provide (all-from-out "../resource.rkt"))

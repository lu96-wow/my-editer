#lang racket

;;; api/world.rkt —— 公共 API 面：应用世界状态
;;;
;;; 转发 app/world.rkt：world / ctx / mode / app-event / drag + 构造、派生、ref 解析。
;;; 此文件只转发，不放逻辑。

(require "../world.rkt")
(provide (all-from-out "../world.rkt"))

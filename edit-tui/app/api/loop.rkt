#lang racket

;;; api/loop.rkt —— 公共 API 面：事件循环
;;;
;;; 转发 app/loop.rkt：run-app（唯一不纯的入口）。此文件只转发，不放逻辑。

(require "../loop.rkt")
(provide (all-from-out "../loop.rkt"))

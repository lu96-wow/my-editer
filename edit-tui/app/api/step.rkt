#lang racket

;;; api/step.rkt —— 公共 API 面：纯状态转移
;;;
;;; 转发 app/step.rkt：world-step / world-step*。此文件只转发，不放逻辑。

(require "../step.rkt")
(provide (all-from-out "../step.rkt"))

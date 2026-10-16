#lang racket

;;; api/intent.rkt —— 公共 API 面：效果词汇（intent）
;;;
;;; 转发 app/intent.rkt。用户拿这份即可表达「状态意图 update」与「效果意图」，
;;; 不必知道 step / loop 的内部结构。此文件只转发，不放逻辑。

(require "../intent.rkt")
(provide (all-from-out "../intent.rkt"))

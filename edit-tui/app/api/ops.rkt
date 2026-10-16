#lang racket

;;; api/ops.rkt —— 公共 API 面：操作根对象的纯原语
;;;
;;; 转发 app/ops.rkt：layout / 切分关闭（读 role）/ 焦点 / document 原语。
;;; 此文件只转发，不放逻辑。

(require "../ops.rkt")
(provide (all-from-out "../ops.rkt"))

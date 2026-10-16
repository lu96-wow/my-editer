#lang racket

;;; api/panel-ref.rkt —— 公共 API 面：panel 稳定身份与解析
;;;
;;; 转发 app/panel-ref.rkt：leaf/float 的 ref、ref → 当帧 view/panel、panels ↔ refs。
;;; 此文件只转发，不放逻辑。

(require "../panel-ref.rkt")
(provide (all-from-out "../panel-ref.rkt"))

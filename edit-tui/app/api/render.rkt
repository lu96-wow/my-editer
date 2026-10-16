#lang racket

;;; api/render.rkt —— 公共 API 面：world → bytes 渲染投影
;;;
;;; 转发 app/render.rkt：draw-world / world-display-panels（焦点边框投影）。
;;; 此文件只转发，不放逻辑。

(require "../render.rkt")
(provide (all-from-out "../render.rkt"))

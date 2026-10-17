#lang racket

;;; api/status.rkt —— 公共 API 面：状态栏文本投影
;;;
;;; 转发 app/status.rkt：status-line（纯投影）/ status-sync! / status-position /
;;; status-path / status-sequence。此文件只转发，不放逻辑。

(require "../status.rkt")
(provide (all-from-out "../status.rkt"))

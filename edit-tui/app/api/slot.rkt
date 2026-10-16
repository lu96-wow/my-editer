#lang racket

;;; api/slot.rkt —— 公共 API 面：底部共享槽（状态栏 / 输入栏）
;;;
;;; 转发 app/slot.rkt：slot-install / slot-show / slot-show-status / slot-show-input /
;;; slot-active / status-sync!。此文件只转发，不放逻辑。

(require "../slot.rkt")
(provide (all-from-out "../slot.rkt"))

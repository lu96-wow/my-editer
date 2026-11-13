#lang racket

;;; edit-tui/core/face/style.rkt —— 命名样式值（纯）
;;;
;;; theme 配置只产出这些纯值；把它们翻译成 tui 样式是 host 的事。
;;;
;;; fg / bg : #f | (rgb r g b) | 0..255
;;; attrs   : (listof 'bold 'dim 'italic 'underline 'blink 'reverse)

(provide (struct-out rgb)
         (struct-out style))

(struct rgb (r g b) #:prefab)
(struct style (fg bg attrs) #:prefab)

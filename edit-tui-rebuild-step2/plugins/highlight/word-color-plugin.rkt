#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯装配；计算在 effects/paint 的 slot fork 里跑）
;;;
;;; word-color-plugin.rkt —— 同词同色插件（只对 Racket 文件生效）。

(provide word-color-plugin)

(require "../../env/environment.rkt"
         "../../env/plugin.rkt"
         "word-color-decor.rkt")

(define (word-color-plugin #:enabled? [enabled? #t])
  (make-plugin
   'word-color
   #:env (make-environment #:face-layers (list 'word-color))
   #:decors (if enabled? (list word-color-face-decor) '())))

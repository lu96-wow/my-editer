#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯装配；计算在 effects/paint 的 slot fork 里跑）
;;;
;;; words-plugin.rkt —— 光标当前 token 背景高亮（对所有文档生效）。

(provide words-plugin)

(require "../../env/environment.rkt"
         "../../env/plugin.rkt"
         "words-decor.rkt")

(define (words-plugin #:enabled? [enabled? #t])
  (make-plugin
   'words
   #:env (make-environment #:face-layers (list 'words))
   #:decors (if enabled? (list words-face-decor) '())))

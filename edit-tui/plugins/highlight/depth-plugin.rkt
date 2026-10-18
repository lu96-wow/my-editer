#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯装配；计算在 effects/paint 的 slot fork 里跑）
;;;
;;; plugins/highlight/depth-plugin.rkt —— 括号深度底色（背景层，增量 decor）
;;;
;;; 它与 syntax-fg 互不覆盖：本插件只写背景分量，语法层只写前景分量。
;;; 两个 decor 的状态 / layer 都挂在该 document 的 paint slot 上，按层序合成。

(provide depth-bg-plugin)

(require "../../env/environment.rkt"
         "../../env/plugin.rkt"
         "depth-decor.rkt")

(define (depth-bg-plugin #:enabled? [enabled? #t])
  (make-plugin
   'depth-bg
   #:env (make-environment #:face-layers (list 'depth-bg))
   #:decors (if enabled? (list depth-face-decor) '())))

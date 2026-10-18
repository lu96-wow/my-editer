#lang racket

;;; layer  : plugins/highlight
;;; effect : 无（纯装配；计算在 effects/paint 的 slot fork 里跑）
;;;
;;; plugins/highlight/plugin.rkt —— 语法高亮（前景层，增量 decor）
;;;
;;; 它不是 hook：每个文档有一份词法状态 + 一条 layer track（挂在 document slot 上）。
;;; 文本编辑时 core 的 slot fork 调 `syntax-change`，只重扫脏行；undo 回放旧
;;; document 时旧状态 / 旧层自动回来。
;;;
;;; 层名 = syntax-fg；只写前景分量，和 depth-bg 的背景层按层序合成。

(provide highlight-plugin)

(require "../../env/environment.rkt"
         "../../env/plugin.rkt"
         "syntax-decor.rkt")

(define (highlight-plugin #:enabled? [enabled? #t])
  (make-plugin
   'highlight
   #:env (make-environment #:face-layers (list 'syntax-fg))
   #:decors (if enabled? (list syntax-face-decor) '())))

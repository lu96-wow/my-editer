#lang racket

(require "api.rkt"
         "brackets.rkt"
         "words.rkt"
         "syntax.rkt")

;;; lab/plugin/registry.rkt —— 内置插件表（主进程与后台 worker 共用同一份）
;;;
;;; **列表顺序 = 应用/层叠顺序**：后面的插件后写，同名通道（前景/背景）覆盖前面的，
;;; 但不同通道同时保留（括号背景 + 语法前景共存）。
;;;   brackets  括号背景（最底层）
;;;   words     词前景
;;;   syntax    Racket 关键字前景（最上层，覆盖词色）
;;;
;;; 后台进程只收到插件 name，用 registry-ref 查到同一个 compute，保证两边一致。

(provide registry-plugins registry-ref)

(define registry-plugins
  (list bracket-plugin
        word-plugin
        syntax-plugin))

(define (registry-ref name)
  (for/first ([p (in-list registry-plugins)] #:when (eq? name (plugin-name p))) p))

#lang racket

(require "api.rkt"
         "brackets.rkt")

;;; lab/plugin/registry.rkt —— 内置插件表（主进程与后台 worker 共用同一份）
;;;
;;; 后台进程只收到插件 name，用 registry-ref 查到同一个 compute，保证两边一致。

(provide registry-plugins registry-ref)

(define registry-plugins
  (list bracket-plugin))

(define (registry-ref name)
  (for/first ([p (in-list registry-plugins)] #:when (eq? name (plugin-name p))) p))

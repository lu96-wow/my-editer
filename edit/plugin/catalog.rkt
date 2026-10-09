#lang racket

;;; edit/plugin/catalog.rkt —— 内置 document 插件**目录**（能力清单）
;;;
;;; **列表顺序 = 应用 / 层叠顺序**：后面的插件后写，同一格合成 face-stack。
;;; 「这次启用哪些」是 config/plugins.rkt（只给名字）；本文件把名字解析成实现。
;;; 目录随插件增多而增长；config 永远不认识实现。

(require "registry.rkt"
         "builtin/words.rkt"
         "builtin/syntax.rkt"
         "../config/plugins.rkt")

(provide plugin-catalog registry-ref plugins-by-names enabled-doc-plugins)

(define plugin-catalog
  (list word-plugin
        syntax-plugin))

(define (registry-ref name)
  (for/first ([p (in-list plugin-catalog)] #:when (eq? name (doc-plugin-name p))) p))

(define (plugins-by-names names)
  (for/list ([n (in-list names)] #:when (registry-ref n))
    (registry-ref n)))

;; 装配时用的「启用插件集」（顺序 = 目录顺序）。
(define enabled-doc-plugins (plugins-by-names enabled-doc-plugin-names))

#lang racket

(require "api.rkt"
         "brackets.rkt"
         "words.rkt"
         "syntax.rkt"
         "../../config/plugins.rkt")

;;; lab-re-rebuild/plugin/attr/registry.rkt —— 内置属性插件**目录**（能力清单）
;;;
;;; **列表顺序 = 应用 / 层叠顺序**：后面的插件后写，同名通道（前景 / 背景）覆盖前面的，
;;; 但不同通道同时保留（括号背景 + 语法前景共存）。
;;;   brackets  括号背景（最底层）
;;;   words     词前景
;;;   syntax    Racket 关键字前景（最上层，覆盖词色）
;;;
;;; 「这次启用哪些」是**配置**（config/plugins.rkt，只给名字）；本文件负责把名字解析
;;; 成实现。后台 worker 也用同一份 config + 本目录解析，保证主进程 / 进程外一致。

(provide plugin-catalog registry-ref plugins-by-names enabled-attr-plugins)

(define plugin-catalog
  (list bracket-plugin
        word-plugin
        syntax-plugin))

(define (registry-ref name)
  (for/first ([p (in-list plugin-catalog)] #:when (eq? name (plugin-name p))) p))

(define (plugins-by-names names)
  (for/list ([n (in-list names)] #:unless (not (registry-ref n)))
    (registry-ref n)))

(define enabled-attr-plugins (plugins-by-names attr-plugin-names))

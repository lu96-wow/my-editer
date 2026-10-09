#lang racket

;;; edit/plugin/catalog.rkt —— 内置插件**目录**（能力清单）+ 装配
;;;
;;; 一个插件 = plugin-spec（名字 + 全局 install + 它带的 document 插件）。
;;; **列表顺序 = 应用 / 层叠顺序**（doc 插件的 fills 顺序、全局 install 顺序）。
;;; 「这次启用哪些」是 config/plugins.rkt（只给名字）；本文件把名字解析成实现，
;;; 装配时 install-plugins 装全局贡献，enabled-doc-plugins 交给 rules 绑定。

(require "registry.rkt"
         "builtin/words.rkt"
         "builtin/syntax.rkt"
         "builtin/completion.rkt"
         "../config/plugins.rkt")

(provide plugin-catalog registry-ref plugins-by-names
         enabled-plugins enabled-doc-plugins install-plugins)

(define plugin-catalog
  (list word-spec
        syntax-spec
        completion-spec))

(define (registry-ref name)
  (for/first ([p (in-list plugin-catalog)] #:when (eq? name (plugin-spec-name p))) p))

;; 名字 → 实现；未知名字直接报错（配置拼错不静默）。
(define (plugins-by-names names)
  (for/list ([n (in-list names)])
    (or (registry-ref n)
        (error 'plugins-by-names "未知插件名: ~a（可用: ~a）"
               n (map plugin-spec-name plugin-catalog)))))

(define enabled-plugins (plugins-by-names enabled-plugin-names))

;; 启用插件带的 document 插件（顺序 = 目录顺序）。
(define enabled-doc-plugins
  (append* (for/list ([p (in-list enabled-plugins)]) (plugin-spec-doc-plugins p))))

;; 装所有启用插件的全局贡献（hook / layer / handler / panel…）。
(define (install-plugins s)
  (for/fold ([s s]) ([p (in-list enabled-plugins)]) ((plugin-spec-install p) s)))

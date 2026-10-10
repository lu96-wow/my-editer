#lang racket

;;; edit-rebuild/plugins/catalog.rkt —— 插件**目录**（能力清单）与启用解析
;;;
;;; 一个插件 = plugin-spec（名字 + 全局 install + 它带的 face 插件）。
;;; **列表顺序 = 应用 / 层叠顺序**（face 插件的 fills 顺序、全局 install 顺序）。
;;; 「这次启用哪些」是 config/plugins.rkt（只给名字）；本文件把名字解析成实现。
;;;
;;; 装配（装全局贡献 / 取 face 插件 / 绑定规则）由 app 用 extension/spec 的通用器完成。

(require "../core/extension/spec.rkt"
         "ui/status.rkt"
         "ui/prompt.rkt"
         "ui/log.rkt"
         "ui/tree.rkt"
         "ui/buffers.rkt"
         "ui/document.rkt"
         "ui/lifecycle.rkt"
         "highlight/brackets.rkt"
         "highlight/words.rkt"
         "highlight/syntax.rkt"
         "completion/main.rkt"
         "docs/main.rkt"
         "enabled.rkt")

(provide plugin-catalog registry-ref plugins-by-names enabled-plugins)

(define plugin-catalog
  (list status-spec
        prompt-spec
        log-spec
        tree-spec
        buffers-spec
        document-spec
        lifecycle-spec
        bracket-spec
        word-spec
        syntax-spec
        completion-spec
        docs-spec))

(define (registry-ref name)
  (for/first ([p (in-list plugin-catalog)] #:when (eq? name (plugin-spec-name p))) p))

;; 名字 → 实现；未知名字直接报错（配置拼错不静默）。
(define (plugins-by-names names)
  (for/list ([n (in-list names)])
    (or (registry-ref n)
        (error 'plugins-by-names "未知插件名: ~a（可用: ~a）"
               n (map plugin-spec-name plugin-catalog)))))

(define enabled-plugins (plugins-by-names enabled-plugin-names))

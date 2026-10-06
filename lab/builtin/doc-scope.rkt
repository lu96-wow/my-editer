#lang racket

;;; lab/builtin/doc-scope.rkt —— 「能力对哪些文档启用」的声明与查询（独立关注点）。
;;;
;;; 独立文件、独立逻辑：一个**能力**（补全 / 文档查询 / 缩进 …）是否对当前文档启用。
;;; 与补全 / 菜单 / 异步无关，只做两件事：
;;;   声明：contrib kind 'doc-scope，value = (doc-scope applies?)
;;;   查询：doc-applies? ctx name —— 取当前活动编辑文档的 (path text) 交给谓词
;;; 无声明 → 默认对所有文档启用。
;;;
;;; 与属性插件的 per-plugin `applies?` 同源（都吃 (path text)）：插件那条要能进 worker，
;;; 所以留在 plugin 结构里；这里是**功能级**，进主进程 registry。

(require "../kernel/editor-api.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../kernel/paths.rkt")

(provide (struct-out doc-scope) doc-applies? current-doc)

(struct doc-scope (applies?) #:transparent)
;; applies? : path text -> boolean

;; 当前活动编辑视图的 (values path text)；无编辑视图 → (values #f #f)。
(define (current-doc ctx)
  (define s (ctx-session ctx))
  (define vid (session-edit-vid s))
  (cond
    [(not vid) (values #f #f)]
    [else
     (define ed (session-editor s))
     (define did (editor-view-document-id ed vid))
     (values (path-table-path (session-paths s) did)
             (editor-view-string ed vid))]))

;; 能力 name 对当前文档是否启用。无声明 → #t。
(define (doc-applies? ctx name)
  (define c (reg-ref (runtime-registry (ctx-runtime ctx)) 'doc-scope name))
  (cond
    [(not c) #t]
    [else
     (define-values (path text) (current-doc ctx))
     ((doc-scope-applies? (contrib-value c)) path text)]))

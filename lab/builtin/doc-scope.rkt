#lang racket

;;; lab/builtin/doc-scope.rkt —— 「能力对哪些文档启用」的声明与查询（独立关注点）。
;;;
;;; 独立文件、独立逻辑：一个**能力**（补全 / 文档查询 / 缩进 …）是否对当前文档启用。
;;; 与补全 / 菜单 / 异步无关，只做两件事：
;;; 声明：contrib kind 'doc-scope，value = (doc-scope applies?)
;;;   查询：doc-applies? ctx name —— 取当前活动编辑文档的 path + 「取 text 的 thunk」交给谓词
;;; 无声明 → 默认对所有文档启用。
;;;
;;; 谓词吃 (path get-text)：因为多数谓词只看 path（扩展名），不该为了一个用不到的
;;; 全文而在每键把整篇 document->string（大文件上百 ms、超线性）。text 仅当谓词
;;; 真的 force 时才计算。与属性插件的 per-plugin `applies?` 同源（那条吃真 text，
;;; 要能进 worker，所以留在 plugin 结构里）。

(require "../kernel/editor-api.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../kernel/paths.rkt")

(provide (struct-out doc-scope) doc-applies? current-doc current-doc-path current-doc-text)

(struct doc-scope (applies?) #:transparent)
;; applies? : path (-> string) -> boolean

;; 当前活动编辑视图的 path（O(1)）。
(define (current-doc-path ctx)
  (define s (ctx-session ctx))
  (define vid (session-edit-vid s))
  (cond
    [(not vid) #f]
    [else
     (define ed (session-editor s))
     (define did (editor-view-document-id ed vid))
     (path-table-path (session-paths s) did)]))

;; 当前文档全文（O(全文)）；只在谓词 force 时算。
(define (current-doc-text ctx)
  (define s (ctx-session ctx))
  (define vid (session-edit-vid s))
  (and vid (editor-view-string (session-editor s) vid)))

;; 兼容入口：当前活动编辑视图的 (values path text)；无编辑视图 → (values #f #f)。
(define (current-doc ctx)
  (values (current-doc-path ctx) (current-doc-text ctx)))

;; 能力 name 对当前文档是否启用。无声明 → #t。
(define (doc-applies? ctx name)
  (define c (reg-ref (runtime-registry (ctx-runtime ctx)) 'doc-scope name))
  (cond
    [(not c) #t]
    [else
     ((doc-scope-applies? (contrib-value c))
      (current-doc-path ctx)
      (λ () (current-doc-text ctx)))]))

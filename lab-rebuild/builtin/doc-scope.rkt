#lang racket

;;; lab-rebuild/builtin/doc-scope.rkt —— 「能力对哪些文档启用」的声明与查询。
;;;
;;; 一个**能力**（缩进 / 补全 / 文档查询 …）是否对当前文档启用，是一个独立关注点：
;;; 只做两件事，不与补全 / 菜单 / 异步耦合。
;;;
;;;   声明：contrib kind 'doc-scope，name = 能力名，value = (doc-scope applies?)
;;;         applies? : path (-> string) -> boolean
;;;   查询：doc-applies? ctx name —— 取当前活动编辑文档的 path + 「取 text 的 thunk」交给谓词。
;;;         无声明 → 默认对所有文档启用。
;;;
;;; 谓词吃 (path get-text)：多数谓词只看 path（扩展名），不该为了一个用不到的全文而在
;;; 每键把整篇 document->string（大文件上百 ms）。text 仅当谓词真的 force 时才计算。
;;;
;;; 路径来源是 document-api.rkt（接口），不是 session；调用方不 require document 实现。

(require "../kernel/api.rkt"
         "document-api.rkt")

(provide (struct-out doc-scope)
         doc-applies?
         current-doc current-doc-path current-doc-text)

(struct doc-scope (applies?) #:transparent)

;; 当前活动编辑视图的 did（O(1)）；无编辑视图 → #f。
(define (current-doc-did ctx)
  (define s (ctx-session ctx))
  (define vid (session-edit-vid s))
  (and vid (editor-view-document-id (session-editor s) vid)))

;; 当前活动编辑视图的 path（O(1)）。
(define (current-doc-path ctx)
  (define did (current-doc-did ctx))
  (and did (doc-path ctx did)))

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
      (lambda () (current-doc-text ctx)))]))

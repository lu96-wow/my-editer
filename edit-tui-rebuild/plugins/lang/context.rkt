#lang racket

;;; layer  : plugins/lang
;;; effect : 无（纯查询：state + engine-view -> 值）
;;;
;;; context.rkt —— 当前文档的源码 / require 上下文（补全与文档共用）
;;;
;;; source-context 只做一次解析，返回：
;;;   path / base-dir / open / lang / forms / specs / parsed / locals
;;; 补全用它算候选池和缓存 key；文档用它算候选模块和绑定来源。

(provide focused-vid
         doc-meta-of-view
         open-local-texts
         source-context
         export-key)

(require (except-in racket/list range)
         racket/path
         "../../base/id.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../effects/engine.rkt"
         "../highlight/kind.rkt"
         "source.rkt")

(define (focused-vid state)
  (define f (state-focus state))
  (and (view-id? f) f))

(define (doc-meta-of-view state vid)
  (define did (and vid (workspace-doc-of-view (state-workspace state) vid)))
  (and did (workspace-doc (state-workspace state) did)))

(define (open-local-texts state ev)
  (for/hash ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
             #:when (doc-meta-path dm))
    (values (path->string (path->complete-path (doc-meta-path dm)))
            (or (engine-view-doc-text ev did) ""))))

;; 解析当前 view 的 Racket require 上下文。非 Racket 文档 -> #f。
(define (source-context state ev vid)
  (define dm (doc-meta-of-view state vid))
  (cond
    [(not (racket-doc-meta? dm)) #f]
    [else
     (define text (or (engine-view-view-text ev vid) ""))
     (define path (doc-meta-path dm))
     (define base-dir
       (if path
           (let-values ([(d _f _n) (split-path path)])
             (if (path? d) d (current-directory)))
           (current-directory)))
     (define-values (lang forms) (requires-context text))
     (define specs0 (require-specs-of-forms lang forms))
     (define specs (if (pair? specs0) specs0 (list 'racket/base)))
     (define parsed (requires-of-forms lang forms #:base-dir base-dir))
     (hash 'path path
           'text text
           'base-dir base-dir
           'open (open-local-texts state ev)
           'lang lang
           'forms forms
           'specs specs
           'parsed parsed
           'locals (map symbol->string (definitions-of-forms forms)))]))

;; 补全缓存 key：spec 结构 + base-dir + 已打开本地文档的当前文本。
(define (export-key ctx)
  (list (hash-ref ctx 'specs)
        (path->string (hash-ref ctx 'base-dir))
        (sort (for/list ([(p t) (in-hash (hash-ref ctx 'open))]) (cons p t))
              string<? #:key car)))

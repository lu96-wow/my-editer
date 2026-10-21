#lang racket

;;; edit-tui/lang/racket/workspace.rkt —— 跨 buffer 的 Racket 解析缓存
;;;
;;; 为什么需要它：
;;;   · 一个 buffer 的 require 可能指向另一个**打开中的 buffer**；
;;;   · 那个 buffer 可能没保存，磁盘内容不是真相；
;;;   · 一个 buffer 改了，依赖它的 buffer 的补全 / 文档必须跟着变。
;;;
;;; 设计：
;;;   workspace = 当前所有打开文档的只读快照
;;;   doc-entry = id / path / text / version / analysis
;;;   analysis 按 (text/version) 缓存；同一份分析被所有查询复用。
;;;
;;; 这是纯值：`workspace-set-doc` 返回新 workspace；旧 workspace 不会被污染。
;;; 编辑器后续只需在每个文档版本变化时调用 workspace-set-doc，不需要自己维护
;;; “哪个 buffer 解析过 / 哪个依赖过期”。
;;;
;;; 注意：本层仍然不 require app / boot / engine；id 是编辑器给的任意值。

(provide (struct-out document-entry)
         (struct-out workspace)
         workspace-empty
         workspace-set-doc
         workspace-apply-changes
         workspace-set-source
         workspace-apply-source-changes
         workspace-remove-source
         workspace-remove-doc
         workspace-doc
         workspace-doc-by-path
         workspace-analysis
         workspace-open-texts
         workspace-path->id
         workspace-export-names
         workspace-imported-names
         workspace-imported-local-docs
         workspace-local-pool
         workspace-local-def
         workspace-local-defs
         workspace-normalize-path)

(require racket/list
         racket/path
         racket/string
         "../../../source/api.rkt"
         "analysis.rkt"
         "local-docs.rkt"
         "pool.rkt"
         "source.rkt")

;;; ════════════════ 数据 ════════════════

(struct document-entry
  (id path text version analysis)
  #:transparent)
;; id       : 任意（编辑器 doc-id / path / 测试用符号）
;; path     : 规范化绝对路径字符串 | #f
;; text     : 当前缓冲区全文
;; version  : 任意版本 token（#f = 用 text 判等）
;; analysis : module-analysis

(struct workspace (docs) #:transparent)
;; docs : hash id -> document-entry

(define workspace-empty (workspace (hash)))

;;; ════════════════ 路径 ════════════════

(define (workspace-normalize-path p)
  (and p
       (let ([path (cond [(path? p) p]
                         [(string? p) (string->path p)]
                         [else (error 'workspace-normalize-path "path 要是 string/path：~a" p)])])
         (path->string (simplify-path (path->complete-path path))))))

(define (entry-base-dir e)
  (define p (document-entry-path e))
  (cond
    [(not p) (current-directory)]
    [else
     (let-values ([(d _f _n) (split-path (string->path p))])
       (if (path? d) d (current-directory)))]))

(define (path->doc-id ws path)
  (define target (workspace-normalize-path path))
  (for/first ([(id e) (in-hash (workspace-docs ws))]
              #:when (equal? (document-entry-path e) target))
    id))

;;; ════════════════ 写入 / 查询 ════════════════

;; workspace-set-doc : ws id path text [#:version v] -> workspace
;;
;; 同一 id / path / version（或 text 相等）时复用旧 analysis。
;; 这是跨 buffer 缓存的第一层：每个文档每版本只解析一次。
(define (workspace-set-doc ws id path text
                           #:version [version #f])
  (define path* (workspace-normalize-path path))
  (define old (hash-ref (workspace-docs ws) id #f))
  (define reuse?
    (and old
         (equal? (document-entry-path old) path*)
         (cond
           [version (equal? (document-entry-version old) version)]
           [else (equal? (document-entry-text old) text)])))
  (define analysis
    (if reuse?
        (document-entry-analysis old)
        (analyze-source path* text)))
  (define entry (document-entry id path* text
                                (or version text)
                                analysis))
  (workspace (hash-set (workspace-docs ws) id entry)))

;; 增量更新：analysis-edit 只重读受影响的顶层 form；依赖查询按新接口即时解析。
(define (workspace-apply-changes ws id path text
                                 #:version [version #f]
                                 #:edits edits)
  (define old (hash-ref (workspace-docs ws) id #f))
  (define path* (workspace-normalize-path path))
  (cond
    [(or (not old)
         (not (equal? (document-entry-path old) path*)))
     (workspace-set-doc ws id path text #:version version)]
    [(null? edits) ws]
    [else
     (define analysis (analysis-edit (document-entry-analysis old) path* text edits))
     (define entry (document-entry id path* text
                                   (or version text)
                                   analysis))
     (workspace (hash-set (workspace-docs ws) id entry))]))

;;; ════════════════ source snapshot 入口 ════════════════

;; workspace 只消费 source snapshot，不关心它来自 buffer 还是 disk。
(define (workspace-set-source ws snapshot)
  (workspace-set-doc ws
                     (source-snapshot-id snapshot)
                     (source-snapshot-path snapshot)
                     (source-snapshot-text snapshot)
                     #:version (source-snapshot-version snapshot)))

(define (workspace-apply-source-changes ws snapshot edits)
  (workspace-apply-changes ws
                           (source-snapshot-id snapshot)
                           (source-snapshot-path snapshot)
                           (source-snapshot-text snapshot)
                           #:version (source-snapshot-version snapshot)
                           #:edits edits))

(define (workspace-remove-source ws id)
  (workspace-remove-doc ws id))

(define (workspace-remove-doc ws id)
  (workspace (hash-remove (workspace-docs ws) id)))

(define (workspace-doc ws id)
  (hash-ref (workspace-docs ws) id #f))

(define (workspace-doc-by-path ws path)
  (define id (path->doc-id ws path))
  (and id (workspace-doc ws id)))

(define (workspace-analysis ws id)
  (define e (workspace-doc ws id))
  (and e (document-entry-analysis e)))

;; 给 pool/spec-names 用的“打开文档”映射：绝对路径 -> 当前 buffer 文本。
(define (workspace-open-texts ws)
  (for/hash ([(id e) (in-hash (workspace-docs ws))]
             #:when (document-entry-path e))
    (values (document-entry-path e) (document-entry-text e))))

(define (workspace-path->id ws path)
  (path->doc-id ws path))

;;; ════════════════ 跨 buffer 导出解析 ════════════════

;; 递归解析 provide / all-from-out。
;; stack 防止 a.rkt ↔ b.rkt 的循环 require 无限递归。
(define (export-names ws id stack)
  (cond
    [(memv id stack) '()]
    [else
     (define e (workspace-doc ws id))
     (cond
       [(not e) '()]
       [else
        (define stack* (cons id stack))
        (define resolver
          (λ (spec) (resolve-spec-exports ws e spec stack*)))
        (with-handlers ([exn:fail? (lambda (_) '())])
          (provides-of-forms* (module-analysis-forms (document-entry-analysis e))
                              #:module-exports resolver))])]))

;; spec -> (listof string)。优先使用 workspace 里的打开文档；否则退回磁盘模块。
(define (resolve-spec-exports ws e spec stack)
  (define base-dir (entry-base-dir e))
  (define open (workspace-open-texts ws))
  (with-handlers ([exn:fail? (lambda (_) '())])
    (cond
      ;; 相对/绝对文件路径：先找打开中的 buffer
      [(string? spec)
       (define path (path->complete-path (string->path spec) base-dir))
       (define id (path->doc-id ws path))
       (cond
         [id (export-names ws id stack)]
         [else (spec-names spec base-dir open)])]
      ;; 包装器 / 模块路径：交给 pool；pool 对打开中的本地文件会读 open 文本。
      [else (spec-names spec base-dir open)])))

(define (workspace-export-names ws id)
  (distinct-strings (export-names ws id '())))

;; 当前文档从 require / #lang 拿到哪些名字。
;; 直接 require 的字符串文件走 workspace 的 analysis 缓存；
;; 其它模块（集合 / lib / 包装器）交给 pool。
(define (workspace-imported-names ws id)
  (define e (workspace-doc ws id))
  (cond
    [(not e) '()]
    [else
     (define a (document-entry-analysis e))
     (define specs (module-analysis-specs a))
     (distinct-strings
      (append* (for/list ([spec (in-list specs)])
                 (with-handlers ([exn:fail? (lambda (_) '())])
                   (resolve-spec-exports ws e spec '())))))]))

(define (distinct-strings ss)
  (define seen (make-hash))
  (reverse
   (for/fold ([acc '()]) ([s (in-list ss)])
     (cond [(hash-ref seen s #f) acc]
           [else (hash-set! seen s #t) (cons s acc)]))))

;;; ════════════════ 依赖 / 本地补全池 ════════════════

;; 直接 require 的本地文件对应的打开文档。
(define (workspace-imported-local-docs ws id)
  (define e (workspace-doc ws id))
  (cond
    [(not e) '()]
    [else
     (define base-dir (entry-base-dir e))
     (define specs (module-analysis-specs (document-entry-analysis e)))
     (define paths
       (append* (for/list ([s (in-list specs)])
                  (with-handlers ([exn:fail? (lambda (_) '())])
                    (spec-local-paths s base-dir)))))
     (for/list ([p (in-list paths)]
                #:do [(define doc (workspace-doc-by-path ws p))]
                #:when doc)
       doc)]))

;; 本地名字：当前文件的所有绑定/定义 + 直接 require 的本地 buffer 的导出。
;; 不包含 all open buffers 的随便什么词 —— 那会把未 import 的名字也塞进来。
(define (workspace-local-pool ws id)
  (define e (workspace-doc ws id))
  (cond
    [(not e) '()]
    [else
     (define a (document-entry-analysis e))
     (define from-current
       (append (module-analysis-bindings a)
               (for/list ([s (in-list (module-analysis-definitions a))])
                 (symbol->string s))))
     (define from-imports
       (append* (for/list ([d (in-list (workspace-imported-local-docs ws id))])
                  (workspace-export-names ws (document-entry-id d)))))
     (distinct-strings (append from-current from-imports))]))

;;; ════════════════ 本地文档 ════════════════

;; 先当前 buffer，再直接 require 的本地 buffer，最后其它打开 buffer。
;; 这样补全 / docs 都能看到“另一个 buffer 里的本地定义”。
(define (workspace-local-def ws id name)
  (define sym (if (symbol? name) name (string->symbol name)))
  (define e (workspace-doc ws id))
  (define required (workspace-imported-local-docs ws id))
  (define others
    (for/list ([(did d) (in-hash (workspace-docs ws))]
               #:unless (or (equal? did id)
                            (for/or ([r (in-list required)])
                              (equal? did (document-entry-id r)))))
      d))
  (define ordered
    (append (if e (list e) '()) required others))
  (for/or ([d (in-list ordered)])
    (define snippet (local-def-of-forms (module-analysis-forms (document-entry-analysis d)) sym))
    (and snippet (cons (document-entry-id d) snippet))))

(define (workspace-local-defs ws id)
  (define e (workspace-doc ws id))
  (if e
      (local-defs (document-entry-text e))
      (hash)))

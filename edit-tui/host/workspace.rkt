#lang racket

;;; edit-tui/host/workspace.rkt —— 来源权威快照 -> 语言 workspace
;;;
;;; 数据流：
;;;   editor resources + disk（host/source.rkt）
;;;     -> source-store
;;;     -> source-store-authoritative-snapshots
;;;     -> 这里
;;;     -> workspace-set-doc
;;;
;;; workspace 是纯值，不属于 State、也不属于 engine：
;;;   · State 不存 cache；
;;;   · engine 只存 buffer / view；
;;;   · source-store 由 host/source.rkt 同步；
;;;   · workspace 由本模块从权威 snapshot 派生。
;;;
;;; 这里不做 IO；只消费 source-store 和 engine 的 fallback 查询。

(require "../lang/source/api.rkt"
         "../lang/racket/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/engine/read.rkt"
         "../editor/resource.rkt")

(provide workspace-sync!)

;;; ════════════════ source snapshot -> workspace ════════════════

;; buffer snapshot 的 id 是 doc-id；disk snapshot 的 id 是 source-id。
;; workspace 里当前 buffer 必须继续用 doc-id，completion / docs 才能按 did 查询。
(define (source->workspace-id s)
  (case (source-snapshot-authority s)
    [(buffer) (source-id-value (source-snapshot-id s))]
    [else (source-snapshot-id s)]))

(define (racket-source? s)
  (or (racket-file? (source-snapshot-path s))
      (racket-text? (source-snapshot-text s))))

(define (sync-source ws s)
  (define id (source->workspace-id s))
  (define path (source-snapshot-path s))
  (define text (source-snapshot-text s))
  (define version (source-snapshot-version s))
  (define entry (workspace-doc ws id))
  (cond
    [(and entry
          (equal? (document-entry-path entry) path)
          (equal? (document-entry-version entry) version))
     (values ws #f)]
    [else
     (values (workspace-set-doc ws id path text #:version version)
             #t)]))

(define (drop-stale ws active)
  (for/fold ([ws ws] [changed? #f])
            ([id (in-list (hash-keys (workspace-docs ws)))])
    (if (member id active)
        (values ws changed?)
        (values (workspace-remove-doc ws id) #t))))

(define (sync-from-sources ed state)
  (define store (editor-sources ed))
  (define snaps
    (filter racket-source?
            (source-store-authoritative-snapshots store)))
  (define active (map source->workspace-id snaps))
  (define old (or (editor-workspace ed) workspace-empty))
  (define-values (ws1 changed1?)
    (for/fold ([ws old] [changed? #f]) ([s (in-list snaps)])
      (define-values (ws* changed*) (sync-source ws s))
      (values ws* (or changed? changed*))))
  (define-values (ws2 changed2?) (drop-stale ws1 active))
  (values ws2 (or changed1? changed2?)))

;;; ════════════════ 没有 source-store 时的兼容 fallback ════════════════

;; 给直接构造 editor 的测试 / 旧入口用；正常 host 路径总是先跑 source-sync!。
(define (doc->resource state)
  (for/hash ([r (in-list (resources-list (state-resources state)))])
    (values (resource-doc-id r) r)))

(define (active-racket-doc-ids ed resources)
  (define engine (editor-engine ed))
  (for/list ([did (in-list (engine-user-doc-ids engine))]
             #:do [(define r (hash-ref resources did #f))]
             #:when (and r (eq? (resource-mode r) 'racket)))
    did))

(define (sync-engine-doc ws ed resources did)
  (define engine (editor-engine ed))
  (define text (engine-doc-text engine did))
  (cond
    [(not text) (values ws #f)]
    [else
     (define r (hash-ref resources did #f))
     (define path (workspace-normalize-path (and r (resource-path r))))
     (define version (engine-doc-version engine did))
     (define entry (workspace-doc ws did))
     (cond
       [(and entry
             (equal? (document-entry-path entry) path)
             (equal? (document-entry-version entry) version))
        (values ws #f)]
       [else
        (values (workspace-set-doc ws did path text #:version version)
                #t)])]))

(define (sync-from-engine ed state)
  (define resources (doc->resource state))
  (define active (active-racket-doc-ids ed resources))
  (define old (or (editor-workspace ed) workspace-empty))
  (define-values (ws1 changed1?)
    (for/fold ([ws old] [changed? #f]) ([did (in-list active)])
      (define-values (ws* changed*) (sync-engine-doc ws ed resources did))
      (values ws* (or changed? changed*))))
  (define-values (ws2 changed2?) (drop-stale ws1 active))
  (values ws2 (or changed1? changed2?)))

;;; ════════════════ 入口 ════════════════

;; → workspace'（仅在变化时写回 editor 实例）
(define (workspace-sync! ed state)
  (define-values (ws changed?)
    (if (editor-sources ed)
        (sync-from-sources ed state)
        (sync-from-engine ed state)))
  (when changed?
    (set-editor-workspace! ed ws))
  ws)

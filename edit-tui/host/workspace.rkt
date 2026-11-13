#lang racket

;;; edit-tui/host/workspace.rkt —— 来源权威快照 -> 语言 workspace
;;;
;;; 数据流：
;;;   editor 打开中的 buffer（host/source.rkt）
;;;     -> source-store（buffer override）
;;;     -> source-store-authoritative-snapshots
;;;     -> 这里
;;;     -> workspace
;;;
;;; 未打开 / 已关闭文件不缓存 disk snapshot；语言层需要时按需读磁盘。
;;;
;;; insert / delete 由 changes hook 调 workspace-note-changes! 做 analysis-edit；
;;; 其他没有 changes hook 的全量路径（open / paste / undo / save-as）在 async
;;; 模式下提交 workspace-analysis job，结果按 (doc-id, version) 校验后安装。
;;;
;;; 同步模式（state-async? = #f）仍然直接全量分析，便于测试 / headless。

(require racket/match
         "../core/api.rkt"
         "../core/job/api.rkt"
         "../lang/source/api.rkt"
         "../lang/racket/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/engine/read.rkt"
         "../editor/job.rkt"
         "../editor/resource.rkt")

(provide workspace-sync!
         workspace-note-changes!
         workspace-pending-analyses
         workspace-install-analysis!
         (struct-out workspace-plugin-state)
         empty-workspace-plugin-state
         workspace-schedule!
         workspace-analysis-service
         workspace-handle-job)

;;; ════════════════ 异步 workspace 分析状态 ════════════════

;; pending : hash doc-id -> version
(struct workspace-plugin-state (pending) #:transparent)

(define empty-workspace-plugin-state
  (workspace-plugin-state (hash)))

(define (workspace-state-pending ps)
  (if (workspace-plugin-state? ps)
      (workspace-plugin-state-pending ps)
      (hash)))

(define (workspace-state-remove-pending ps did version)
  (cond
    [(not (workspace-plugin-state? ps)) ps]
    [else
     (define pending (workspace-plugin-state-pending ps))
     (if (equal? (hash-ref pending did #f) version)
         (workspace-plugin-state (hash-remove pending did))
         ps)]))

;;; ════════════════ changes -> 增量 analysis ════════════════

(define (changes->line-edits changes)
  (for/list ([ch (in-list changes)])
    (define before (change-before ch))
    (define after (change-after ch))
    (line-edit (point-line (range-start before))
               (point-line (range-end before))
               (point-line (range-start after))
               (point-line (range-end after)))))

;; insert / delete 的 changes hook 入口。
;; 只有 workspace entry 正好对应本次编辑前的版本时才走 analysis-edit；
;; 否则留给 workspace-sync! 做全量兜底。
(define (workspace-note-changes! ed state did base-version version changes)
  (define ws (editor-workspace ed))
  (define r (state-resource-for-doc state did))
  (cond
    [(or (not ws) (not r) (not (eq? (resource-mode r) 'racket))) (void)]
    [else
     (define entry (workspace-doc ws did))
     (define path (workspace-normalize-path (resource-path r)))
     (define text (engine-doc-text (editor-engine ed) did))
     (cond
       [(or (not entry)
            (not text)
            (not (equal? (document-entry-path entry) path))
            (not (equal? (document-entry-version entry) base-version)))
        (void)]
       [else
        (set-editor-workspace!
         ed
         (workspace-apply-changes ws did path text
                                  #:version version
                                  #:edits (changes->line-edits changes)))])]))

;;; ════════════════ source snapshot -> workspace ════════════════

;; buffer snapshot 的 id 是 doc-id；disk snapshot 的 id 是 source-id。
(define (source->workspace-id s)
  (case (source-snapshot-authority s)
    [(buffer) (source-id-value (source-snapshot-id s))]
    [else (source-snapshot-id s)]))

(define (racket-source? s)
  (or (racket-file? (source-snapshot-path s))
      (racket-text? (source-snapshot-text s))))

(define (sync-source ws s analyze?)
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
    [analyze?
     (values (workspace-set-doc ws id path text #:version version)
             #t)]
    [else
     ;; async 模式：保留旧 entry，由 workspace-schedule! 提交 job。
     (values ws #f)]))

(define (drop-stale ws active)
  (for/fold ([ws ws] [changed? #f])
            ([id (in-list (hash-keys (workspace-docs ws)))])
    (if (member id active)
        (values ws changed?)
        (values (workspace-remove-doc ws id) #t))))

(define (racket-sources ed)
  (define store (editor-sources ed))
  (and store
       (filter racket-source?
               (source-store-authoritative-snapshots store))))

(define (sync-from-sources ed state analyze?)
  (define snaps (or (racket-sources ed) '()))
  (define active (map source->workspace-id snaps))
  (define old (or (editor-workspace ed) workspace-empty))
  (define-values (ws1 changed1?)
    (for/fold ([ws old] [changed? #f]) ([s (in-list snaps)])
      (define-values (ws* changed*) (sync-source ws s analyze?))
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

(define (sync-engine-doc ws ed resources did analyze?)
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
       [analyze?
        (values (workspace-set-doc ws did path text #:version version)
                #t)]
       [else (values ws #f)])]))

(define (sync-from-engine ed state analyze?)
  (define resources (doc->resource state))
  (define active (active-racket-doc-ids ed resources))
  (define old (or (editor-workspace ed) workspace-empty))
  (define-values (ws1 changed1?)
    (for/fold ([ws old] [changed? #f]) ([did (in-list active)])
      (define-values (ws* changed*)
        (sync-engine-doc ws ed resources did analyze?))
      (values ws* (or changed? changed*))))
  (define-values (ws2 changed2?) (drop-stale ws1 active))
  (values ws2 (or changed1? changed2?)))

;;; ════════════════ 待分析文档 ════════════════

(define (pending-source ws s)
  (define id (source->workspace-id s))
  (define path (source-snapshot-path s))
  (define text (source-snapshot-text s))
  (define version (source-snapshot-version s))
  (define entry (workspace-doc ws id))
  (if (and entry
           (equal? (document-entry-path entry) path)
           (equal? (document-entry-version entry) version))
      '()
      (list (list id path text version))))

(define (pending-engine ws ed resources did)
  (define engine (editor-engine ed))
  (define text (engine-doc-text engine did))
  (cond
    [(not text) '()]
    [else
     (define r (hash-ref resources did #f))
     (define path (workspace-normalize-path (and r (resource-path r))))
     (define version (engine-doc-version engine did))
     (define entry (workspace-doc ws did))
     (if (and entry
              (equal? (document-entry-path entry) path)
              (equal? (document-entry-version entry) version))
         '()
         (list (list did path text version)))]))

;; → (listof (list doc-id path text version))
(define (workspace-pending-analyses ed state)
  (define ws (or (editor-workspace ed) workspace-empty))
  (cond
    [(editor-sources ed)
     (append* (for/list ([s (in-list (or (racket-sources ed) '()))])
                (pending-source ws s)))]
    [else
     (define resources (doc->resource state))
     (append* (for/list ([did (in-list (active-racket-doc-ids ed resources))])
                (pending-engine ws ed resources did)))]))

;;; ════════════════ async job ════════════════

(define (workspace-schedule! ed state ps)
  (cond
    [(not (state-async? state)) (values state ps)]
    [else
     (define old-pending (workspace-state-pending ps))
     (define needed (workspace-pending-analyses ed state))
     (define-values (state* pending*)
       (for/fold ([state state] [pending (hash)]) ([d (in-list needed)])
         (match-define (list did path text version) d)
         (if (equal? (hash-ref old-pending did #f) version)
             (values state (hash-set pending did version))
             (let-values ([(state* job)
                           (state-submit-job state 'workspace-analysis
                                             d (list did version))])
               (values state* (hash-set pending did version))))))
     (values state* (workspace-plugin-state pending*))]))

(define (workspace-analysis-service payload)
  (match-define (list _did path text _version) payload)
  (analyze-source path text))

(define (workspace-install-analysis! ed did path text version analysis)
  (define ws (or (editor-workspace ed) workspace-empty))
  (set-editor-workspace!
   ed
   (workspace-set-analysis ws did path text version analysis)))

(define (workspace-handle-job ed state ps ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'workspace-analysis))
     (values state ps '())]
    [else
     (define tag (job-result-event-tag ev))
     (define did (car tag))
     (define version (cadr tag))
     (define result (job-result-event-result ev))
     (define ps* (workspace-state-remove-pending ps did version))
     (define current-version (engine-doc-version (editor-engine ed) did))
     (cond
       [(job-error? result)
        ;; 保留 pending，避免同一版本每帧重试；等下一次编辑再试。
        (values (state-with-flash
                 state
                 (format "workspace analysis failed: ~a"
                         (job-error-message result)))
                ps
                '())]
       [(not (equal? current-version version))
        (values state ps* '())]
       [else
        (define r (state-resource-for-doc state did))
        (define text (engine-doc-text (editor-engine ed) did))
        (cond
          [(or (not r)
               (not text)
               (not (eq? (resource-mode r) 'racket)))
           (values state ps* '())]
          [else
           (define path (workspace-normalize-path (resource-path r)))
           (workspace-install-analysis! ed did path text version result)
           (values state ps* '())])])]))

;;; ════════════════ 入口 ════════════════

;; async 模式下只同步 entry / 删除 stale；全量 analysis 由
;; workspace-schedule! 提交。同步模式保持原来的行为。
(define (workspace-sync! ed state)
  (define analyze? (not (state-async? state)))
  (define-values (ws changed?)
    (if (editor-sources ed)
        (sync-from-sources ed state analyze?)
        (sync-from-engine ed state analyze?)))
  (when changed?
    (set-editor-workspace! ed ws))
  ws)

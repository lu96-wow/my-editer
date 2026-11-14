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
;;; 用户文本变更（insert / delete / paste / kill-line / undo / redo）都进入
;;; changes hook：
;;;   · 同步模式：直接 analysis-edit；
;;;   · async 模式：只标记 dirty + debounce timer，不分析整篇文本。
;;; timer 到期后提交 workspace-analysis-edit job；没有 changes 的路径（新打开 /
;;; save-as / 外部整篇写回）由 workspace-schedule! 提交全量 workspace-analysis job。
;;; 两类结果都按 (doc-id, version) + job-id 校验后安装。
;;;
;;; workspace 是 host 维护的纯值缓存；不进 State、不属于 engine。

(require racket/match
         "../core/api.rkt"
         "../core/job/api.rkt"
         "../lang/source/api.rkt"
         "../lang/racket/api.rkt"
         "../editor/context.rkt"
         "../editor/state.rkt"
         "../editor/engine/read.rkt"
         "../editor/job.rkt"
         "../editor/resource.rkt"
         "../editor/timer.rkt")

(provide workspace-sync!
         workspace-note-changes!
         workspace-pending-analyses
         workspace-install-analysis!
         (struct-out workspace-plugin-state)
         empty-workspace-plugin-state
         workspace-schedule!
         workspace-analysis-service
         workspace-analysis-edit-service
         workspace-handle-timer
         workspace-handle-job)

;;; ════════════════ 异步 workspace 分析状态 ════════════════

;; 一个 doc 同一时间最多一个 request。
;; kind = 'full | 'incremental
;; timer-id 非 #f：debounce 中；job-id 非 #f：已提交 / 已完成的 job。
(struct workspace-request
  (kind target-version timer-id job-id)
  #:transparent)

(struct workspace-plugin-state
  (requests) ; hash doc-id -> workspace-request
  #:transparent)

(define empty-workspace-plugin-state
  (workspace-plugin-state (hash)))

(define workspace-debounce-ms 100)

(define (workspace-state-requests ps)
  (if (workspace-plugin-state? ps)
      (workspace-plugin-state-requests ps)
      (hash)))

(define (workspace-state-request ps did)
  (hash-ref (workspace-state-requests ps) did #f))

(define (workspace-request-by-timer ps tid)
  (for/first ([(did req) (in-hash (workspace-state-requests ps))]
              #:when (equal? (workspace-request-timer-id req) tid))
    (cons did req)))

(define (workspace-state-set-request ps did req)
  (workspace-plugin-state
   (hash-set (workspace-state-requests ps) did req)))

;; 删除 request，同时取消还没触发的 timer。
(define (workspace-state-remove-request ed ps did)
  (define req (workspace-state-request ps did))
  (cond
    [(not req) ps]
    [else
     (when (workspace-request-timer-id req)
       (editor-cancel-timer! ed (workspace-request-timer-id req)))
     (workspace-plugin-state
      (hash-remove (workspace-state-requests ps) did))]))

(define (workspace-state-remove-request/no-cancel ps did)
  (workspace-plugin-state
   (hash-remove (workspace-state-requests ps) did)))

;;; ════════════════ changes -> 增量 analysis ════════════════

(define (changes->line-edits changes)
  (for/list ([ch (in-list changes)])
    (define before (change-before ch))
    (define after (change-after ch))
    (line-edit (point-line (range-start before))
               (point-line (range-end before))
               (point-line (range-start after))
               (point-line (range-end after)))))

;; 同步路径：保留原行为，直接在当前线程做 analysis-edit。
(define (workspace-apply-changes-sync! ed state did base-version version changes)
  (define ws (editor-workspace ed))
  (define r (state-resource-for-doc state did))
  (cond
    [(or (not ws)
         (not r)
         (not (eq? (engine-doc-kind (editor-engine ed) did) 'user))
         (not (eq? (resource-mode r) 'racket)))
     (void)]
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

;; 用户文本变更的 changes hook 入口。
;; 同步模式直接分析；async 模式只调度 debounce timer，返回新的 plugin state。
(define (workspace-note-changes! ed state ps did base-version version changes)
  (cond
    [(not (state-async? state))
     (workspace-apply-changes-sync! ed state did base-version version changes)
     ps]
    [else
     (define ws (editor-workspace ed))
     (define r (state-resource-for-doc state did))
     (cond
       [(or (not ws)
            (not r)
            (not (eq? (engine-doc-kind (editor-engine ed) did) 'user))
            (not (eq? (resource-mode r) 'racket)))
        ;; 文档已不可分析：清掉旧 timer / request，让 full scheduler 处理。
        (workspace-state-remove-request ed ps did)]
       [else
        (define entry (workspace-doc ws did))
        (define path (workspace-normalize-path (resource-path r)))
        ;; debounce 期间 workspace entry 会停留在上一次已分析版本，因此不能要求
        ;; entry version == 本次 change 的 base-version。timer 到期时用 entry 文本
        ;; 到当前文本做一次粗粒度 diff，就能合并期间的所有编辑。
        (cond
          [(or (not entry)
               (not (equal? (document-entry-path entry) path)))
           ;; 没有可靠 base analysis：下一步走全量。
           (workspace-state-remove-request ed ps did)]
          [else
           (define ps1 (workspace-state-remove-request ed ps did))
           (define tid (editor-schedule-timer! ed workspace-debounce-ms))
           (cond
             [tid
              (workspace-state-set-request
               ps1 did
               (workspace-request 'incremental version tid #f))]
             [else
              ;; 没有 timer service：退回同步，保证 headless 可用。
              (workspace-apply-changes-sync! ed state did base-version version changes)
              ps1])])])]))

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

;;; ════════════════ async job / timer ════════════════

(define (workspace-current-text ed did version)
  (define store (editor-sources ed))
  (define snap (and store
                    (source-store-ref store (source-id 'buffer did))))
  (cond
    [(and snap (equal? (source-snapshot-version snap) version))
     (source-snapshot-text snap)]
    [else
     (engine-doc-text (editor-engine ed) did)]))

(define (workspace-active-ids ed state)
  (cond
    [(editor-sources ed)
     (map source->workspace-id (or (racket-sources ed) '()))]
    [else
     (active-racket-doc-ids ed (doc->resource state))]))

;; async 下只保留仍打开且是 racket 的 doc；关闭的 doc 清掉 timer。
;; 不用“当前待分析列表”来 prune：source snapshot 可能短暂落后，request 本身
;; 才是 pending 的权威标记。
(define (workspace-prune-requests ed ps active-ids)
  (for/fold ([ps ps])
            ([did (in-list (hash-keys (workspace-state-requests ps)))])
    (if (member did active-ids)
        ps
        (workspace-state-remove-request ed ps did))))

(define (workspace-schedule! ed state ps)
  (cond
    [(not (state-async? state)) (values state ps)]
    [else
     (define needed (workspace-pending-analyses ed state))
     (define ps0 (workspace-prune-requests ed ps (workspace-active-ids ed state)))
     (define-values (state* ps*)
       (for/fold ([state state] [ps ps0]) ([d (in-list needed)])
         (match-define (list did path text version) d)
         (define req (workspace-state-request ps did))
         (cond
           ;; debounce / incremental / full 已经在路上。
           [(and req (equal? (workspace-request-target-version req) version))
            (values state ps)]
           [else
            (define ps1 (if req
                            (workspace-state-remove-request ed ps did)
                            ps))
            (define-values (state* job)
              (state-submit-job state 'workspace-analysis
                                d (list did version)))
            (values
             state*
             (workspace-state-set-request
              ps1 did
              (workspace-request 'full version #f (job-id job))))])))
     (values state* ps*)]))

(define (workspace-analysis-service payload)
  (match-define (list _did path text _version) payload)
  (analyze-source path text))

;; payload : (did path old-entry new-text new-version)
(define (workspace-analysis-edit-service payload)
  (match-define (list did path old-entry text version) payload)
  (define entry (workspace-reanalyze-entry old-entry path text #:version version))
  (list did version (document-entry-analysis entry)))

(define (workspace-install-analysis! ed did path text version analysis)
  (define ws (or (editor-workspace ed) workspace-empty))
  (set-editor-workspace!
   ed
   (workspace-set-analysis ws did path text version analysis)))

;; timer 只做状态校验和提交，不读整篇文本、不做 analysis。
(define (workspace-handle-timer ed state ps ev)
  (define found (workspace-request-by-timer ps (timer-event-id ev)))
  (cond
    [(not found) (values state ps '())]
    [else
     (define did (car found))
     (define req (cdr found))
     (define target-version (workspace-request-target-version req))
     (define current-version (engine-doc-version (editor-engine ed) did))
     (define ps* (workspace-state-remove-request/no-cancel ps did))
     (cond
       [(not (equal? current-version target-version))
        (values state ps* '())]
       [else
        (define r (state-resource-for-doc state did))
        (define ws (editor-workspace ed))
        (define entry (and ws (workspace-doc ws did)))
        (define path (and r (workspace-normalize-path (resource-path r))))
        (define text (workspace-current-text ed did target-version))
        (cond
          [(or (not r)
               (not (eq? (resource-mode r) 'racket))
               (not entry)
               (not text)
               (not (equal? (document-entry-path entry) path)))
           ;; 不能增量：下一次 full schedule 处理。
           (values state ps* '())]
          [(equal? (document-entry-version entry) target-version)
           ;; workspace 已经是目标版本，不需要 job。
           (values state ps* '())]
          [else
           (define payload (list did path entry text target-version))
           (define-values (state* job)
             (state-submit-job state 'workspace-analysis-edit
                               payload (list did target-version)))
           (define req*
             (struct-copy workspace-request req
                          [timer-id #f]
                          [job-id (job-id job)]))
           (values state*
                   (workspace-state-set-request ps* did req*)
                   '())])])]))

(define (workspace-job-kind? kind)
  (memq kind '(workspace-analysis workspace-analysis-edit)))

(define (workspace-job-result->analysis kind result did version)
  (cond
    [(eq? kind 'workspace-analysis) result]
    [(and (list? result)
          (= 3 (length result))
          (equal? (list-ref result 0) did)
          (equal? (list-ref result 1) version))
     (list-ref result 2)]
    [else #f]))

(define (workspace-handle-job ed state ps ev)
  (define kind (job-result-event-kind ev))
  (cond
    [(not (workspace-job-kind? kind))
     (values state ps '())]
    [else
     (define tag (job-result-event-tag ev))
     (define did (car tag))
     (define version (cadr tag))
     (define result (job-result-event-result ev))
     (define req (workspace-state-request ps did))
     (define matches?
       (and req
            (equal? (workspace-request-job-id req)
                    (job-result-event-id ev))))
     (cond
       [(job-error? result)
        (cond
          [matches?
           ;; 保留 request，避免同一版本每帧重试；下一次编辑再替换。
           (values (state-with-flash
                    state
                    (format "workspace analysis failed: ~a"
                            (job-error-message result)))
                   ps
                   '())]
          [else (values state ps '())])]
       [(not matches?)
        ;; 旧 job / 已被新 request 取代。
        (values state ps '())]
       [else
        (define ps* (workspace-state-remove-request/no-cancel ps did))
        (define current-version (engine-doc-version (editor-engine ed) did))
        (define analysis (workspace-job-result->analysis kind result did version))
        (cond
          [(not (equal? current-version version))
           (values state ps* '())]
          [(not analysis)
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
              (workspace-install-analysis! ed did path text version analysis)
              (values state ps* '())])])])]))

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

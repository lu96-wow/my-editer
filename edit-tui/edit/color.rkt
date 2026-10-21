#lang racket

;;; edit-tui-rebuild/edit/color.rkt —— 编辑器着色（显式派生阶段）
;;;
;;; 分工：
;;;   1. 纯映射：color-state 的 role -> 逐字符 face track；
;;;   2. 缓存迁移：主线程增量 color-edit / 提交后台 color-open；
;;;   3. 运行时副作用：按 document version 把 face track 写进 view。
;;;
;;; 策略：
;;;   · 普通编辑：主线程 color-edit，只重扫 change 波及的行；
;;;   · 首次打开 / undo / 批量修改：提交 'color-open job；
;;;   · worker 只产出纯 color-job-result / color-job-failure；
;;;   · 主线程在 sync 阶段用当前 document version 校验后消费结果。
;;;
;;; 本模块不消费 pending-doc-changes；run-loop / demo 在显式阶段统一处理。

(require (except-in racket/list range)
         racket/match
         racket/string
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/event.rkt"
         "../lang/racket/api.rkt")

(provide sync-editor-colors!
         handle-color-job-result
         color-services)

;;; ════════════════ 缓存 / 结果值 ════════════════

(define color-cache-store-key 'edit/color)
(define color-result-inbox-key 'edit/color/results)

;; doc-version      : color-state / face-track 对应的 document version
;; color-state      : lang/racket color-state | #f（首次打开或已失效）
;; face-track       : (listof (vectorof (or/c #f face?)))
;; pending-version  : 正在后台计算的 document version | #f
;; failed-version   : 该版本后台计算失败，避免同一版本反复重试 | #f
(struct color-cache-entry
  (doc-version color-state face-track pending-version failed-version)
  #:transparent)

(struct color-job-result (did doc-version color-state face-track)
  #:transparent)

(struct color-job-failure (did doc-version message)
  #:transparent)

(define (color-cache-entry-current? entry doc-version)
  (and entry
       (equal? (color-cache-entry-doc-version entry) doc-version)))

(define (color-cache-entry-pending? entry)
  (and entry (color-cache-entry-pending-version entry) #t))

(define (color-cache-entry-failed? entry doc-version)
  (and entry
       (equal? (color-cache-entry-failed-version entry) doc-version)))

(define (empty-color-cache-entry)
  (color-cache-entry #f #f '() #f #f))

;;; ════════════════ 纯映射：role -> face track ════════════════

(define (racket-doc? path text)
  (if path
      (racket-file? path)
      (racket-text? text)))

(define (bracket-role? role)
  (and role
       (string-prefix? (symbol->string role) "bracket-depth-")))

;; 括号 role 是背景层，其余 role 是前景层。
(define (role->face-layer role)
  (if (bracket-role? role)
      (face #f role '())
      (face role #f '())))

;; 固定层序：括号底色 -> 同词前景 -> 语法前景。
;; syntax 只覆盖 fg / attrs，不冲掉括号 bg。
(define (combine-line-role-layers syntax-roles word-roles bracket-roles)
  (define n (vector-length syntax-roles))
  (define out (make-vector n #f))
  (for ([i (in-range n)])
    (define f #f)
    (define br (and bracket-roles
                    (< i (vector-length bracket-roles))
                    (vector-ref bracket-roles i)))
    (when br (set! f (compose-face f (role->face-layer br))))
    (define wr (and word-roles
                    (< i (vector-length word-roles))
                    (vector-ref word-roles i)))
    (when wr (set! f (compose-face f (role->face-layer wr))))
    (define sr (and syntax-roles
                    (< i (vector-length syntax-roles))
                    (vector-ref syntax-roles i)))
    (when sr (set! f (compose-face f (role->face-layer sr))))
    (vector-set! out i f))
  out)

(define (color-state->face-track color-state)
  (for/list ([syntax (in-list (color-syntax-roles color-state))]
             [word (in-list (color-word-roles color-state))]
             [bracket (in-list (color-bracket-roles color-state))])
    (combine-line-role-layers syntax word bracket)))

;;; ════════════════ 编辑变更 -> 语言层 line-edit ════════════════

(define (changes->line-edits changes)
  (for/list ([ch (in-list changes)])
    (define before (change-before ch))
    (define after (change-after ch))
    (line-edit (point-line (range-start before))
               (point-line (range-end before))
               (point-line (range-start after))
               (point-line (range-end after)))))

(define (pending-changes-for-doc pending did)
  (for/list ([dc (in-list pending)]
             #:when (equal? (doc-change-doc-id dc) did))
    dc))

;;; ════════════════ 缓存迁移（纯） ════════════════

;; 消费后台结果。只有结果版本等于当前 document version 才接受。
;; 过期成功结果：清 pending / 旧 state，保留旧 face 供当前文本继续显示。
;; 失败结果：同一版本不重试；文本版本变化后自然会重新请求。
(define (accept-color-job-result entry result doc-version)
  (cond
    [(not result) entry]

    [(color-job-result? result)
     (cond
       [(equal? (color-job-result-doc-version result) doc-version)
        (if (color-cache-entry-current? entry doc-version)
            entry
            (color-cache-entry doc-version
                               (color-job-result-color-state result)
                               (color-job-result-face-track result)
                               #f
                               #f))]
       [else
        (if (and entry
                 (equal? (color-cache-entry-pending-version entry)
                         (color-job-result-doc-version result)))
            (struct-copy color-cache-entry entry
                         [pending-version #f]
                         [color-state #f]
                         [failed-version #f])
            entry)])]

    [(color-job-failure? result)
     (if (and entry
              (equal? (color-cache-entry-pending-version entry)
                      (color-job-failure-doc-version result)))
         (struct-copy color-cache-entry entry
                      [pending-version #f]
                      [color-state #f]
                      [failed-version (color-job-failure-doc-version result)])
         entry)]

    [else entry]))

;; 返回 (values entry' state')；state' 只在提交 job 时变化。
(define (advance-color-cache-entry state old did doc-version text doc-changes)
  (cond
    ;; 该版本后台失败：保持现状，等文本版本变化后再试。
    [(color-cache-entry-failed? old doc-version)
     (values old state)]

    ;; 已是当前版本且没有 outstanding job。
    [(and (color-cache-entry-current? old doc-version)
          (not (color-cache-entry-pending? old)))
     (values old state)]

    ;; 一次只允许一个全量 job；等它回来后再决定是否重发。
    [(color-cache-entry-pending? old)
     (values old state)]

    ;; 有旧 state，且只有一个 change 正好到当前版本：主线程增量。
    [(and old
          (color-cache-entry-color-state old)
          (= (length doc-changes) 1)
          (equal? (doc-change-version (car doc-changes)) doc-version))
     (define color-state
       (color-edit (color-cache-entry-color-state old)
                   text
                   (changes->line-edits
                    (doc-change-changes (car doc-changes)))))
     (values (color-cache-entry doc-version
                                color-state
                                (color-state->face-track color-state)
                                #f
                                #f)
             state)]

    ;; 首次打开 / undo-redo / 批量修改 / 上次失败后版本变化：后台全量。
    [else
     (define-values (state* _job)
       (app-state-submit-job state 'color-open
                             (list 'color-open did doc-version text)
                             (list did doc-version)))
     (define base (or old (empty-color-cache-entry)))
     (values (struct-copy color-cache-entry base
                          [pending-version doc-version]
                          [failed-version #f])
             state*)]))

;;; ════════════════ 主线程 sync 阶段 ════════════════

(define (apply-current-face-track! engine did doc-version views entry)
  (when (color-cache-entry-current? entry doc-version)
    (for ([vid (in-list views)])
      (engine-set-view-face-track! engine vid
                                   (color-cache-entry-face-track entry)
                                   #:base-version doc-version
                                   #:key (list did doc-version 'racket)))))

(define (clear-non-racket-face-track! engine did doc-version views)
  (for ([vid (in-list views)])
    (engine-set-view-face-track! engine vid
                                 '()
                                 #:base-version doc-version
                                 #:key (list did doc-version 'not-racket))))

(define (sync-editor-colors! state engine)
  (define resource-store (app-state-resources state))
  (define pending-changes (app-state-pending-doc-changes state))
  (define old-cache
    (hash-ref (app-state-store state) color-cache-store-key (hash)))
  (define result-inbox
    (hash-ref (app-state-store state) color-result-inbox-key (hash)))

  (define-values (new-cache state*)
    (for/fold ([cache (hash)] [st state])
              ([resource (in-list (resource-list resource-store))])
      (define did (resource-doc-id resource))
      (define path (resource-path resource-store (resource-id resource)))
      (define text (and did (engine-doc-text engine did)))
      (cond
        ;; 边界：resource 尚未在 engine 落地 / 没有文本。
        [(not (and did text)) (values cache st)]

        [else
         (define doc-version (engine-doc-version engine did))
         (define views (resource-views resource))

         (cond
           [(racket-doc? path text)
            (define old-entry (hash-ref old-cache did #f))
            (define pending-result (hash-ref result-inbox did #f))
            (define entry0
              (accept-color-job-result old-entry pending-result doc-version))
            (define-values (entry st*)
              (advance-color-cache-entry st entry0 did doc-version text
                                         (pending-changes-for-doc pending-changes did)))
            (apply-current-face-track! engine did doc-version views entry)
            (values (hash-set cache did entry) st*)]

           ;; 边界：非 Racket 文档要清掉 save-as / 改扩展名前的旧 face。
           [else
            (clear-non-racket-face-track! engine did doc-version views)
            (values cache st)])])))

  ;; result inbox 是一次性投递箱：本帧所有当前 resource 都已检查过，清空。
  (struct-copy app-state state*
               [store (hash-set (hash-set (app-state-store state*)
                                          color-cache-store-key new-cache)
                                color-result-inbox-key
                                (hash))]))

;;; ════════════════ 后台 job / result 接线 ════════════════

(define (color-open-job-handler payload)
  (match-define (list 'color-open did doc-version text) payload)
  (define color-state (color-open text))
  (color-job-result did doc-version color-state
                    (color-state->face-track color-state)))

(define color-services
  (list (service 'color-open color-open-job-handler)))

;; run-loop / demo 在 job-finish 之后调用。这里只把结果放进一次性 inbox；
;; 版本校验在 sync（能拿到 engine 当前 version）里做。
(define (color-job-failure-of-event ev)
  (define result (job-result-event-result ev))
  (cond
    [(color-job-result? result) #f]
    [else
     (define tag (job-result-event-tag ev))
     (define did (and (pair? tag) (car tag)))
     (define doc-version (and (pair? tag) (pair? (cdr tag)) (cadr tag)))
     (and did doc-version
          (color-job-failure did doc-version
                             (if (job-error? result)
                                 (job-error-message result)
                                 result)))]))

(define (handle-color-job-result state ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'color-open)) state]
    [else
     (define result
       (or (let ([r (job-result-event-result ev)])
             (and (color-job-result? r) r))
           (color-job-failure-of-event ev)))
     (cond
       [(not result) state]
       [else
        (define inbox
          (hash-ref (app-state-store state) color-result-inbox-key (hash)))
        (define did
          (if (color-job-result? result)
              (color-job-result-did result)
              (color-job-failure-did result)))
        (struct-copy app-state state
                     [store (hash-set (app-state-store state)
                                      color-result-inbox-key
                                      (hash-set inbox did result))])])]))

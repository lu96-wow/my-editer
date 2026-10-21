#lang racket

;;; edit-tui-rebuild/edit/color.rkt —— 编辑器着色同步（显式派生阶段 + 后台全量）
;;;
;;; 策略：
;;;   · 普通编辑：主线程直接 color-edit，只重扫脏行；
;;;   · 首次打开 / undo / 批量修改：提交 'color-open job，worker 做全量 color-open；
;;;   · worker 只产出纯 color-result，主线程在 sync 阶段校验版本后写 face。
;;;
;;; 缓存放在 app-state.store 的 'edit/color 键下；异步结果暂存在
;;; 'edit/color/results，下一次 sync 用当前 engine version 校验后消费。
;;;
;;; 这里不消费 / 清空 pending-doc-changes：其他派生阶段（如 completion）也要看。
;;; 真正的消费 / 清理由 run-loop 或 demo 的显式阶段决定。

(require (except-in racket/list range)
         racket/match
         racket/string
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../app/event.rkt"
         "../lang/racket/api.rkt")

(provide sync-editor-colors!
         handle-color-job-result
         color-services
         editor-color-cache-key)

(define editor-color-cache-key 'edit/color)
(define editor-color-result-key 'edit/color/results)

;; version         : 当前 state / faces 对应的 engine document version
;; state           : lang/racket color-state | #f
;; faces           : (listof (vectorof (or/c #f face?)))
;; pending-version : 正在后台计算的 version | #f
(struct color-entry (version state faces pending-version) #:transparent)

;; worker -> main 的纯结果
(struct color-result (did version state faces) #:transparent)

(define (racket-doc? path text)
  (if path
      (racket-file? path)
      (racket-text? text)))

(define (bracket-role? role)
  (and role
       (string-prefix? (symbol->string role) "bracket-depth-")))

;; role -> face。括号 role 是背景，其余 role 是前景 + 主题里自带的 attrs。
(define (role-face role)
  (if (bracket-role? role)
      (face #f role '())
      (face role #f '())))

;; 按 edit4 的层序：括号底色 -> 同词前景 -> 语法前景。
;; compose-face 是逐分量覆盖，所以语法只拿 fg，不冲掉括号 bg。
(define (combine-line syntax word bracket)
  (define n (vector-length syntax))
  (define out (make-vector n #f))
  (for ([i (in-range n)])
    (define f #f)
    (define br (and bracket
                    (< i (vector-length bracket))
                    (vector-ref bracket i)))
    (when br (set! f (compose-face f (role-face br))))
    (define wr (and word
                    (< i (vector-length word))
                    (vector-ref word i)))
    (when wr (set! f (compose-face f (role-face wr))))
    (define sr (and syntax
                    (< i (vector-length syntax))
                    (vector-ref syntax i)))
    (when sr (set! f (compose-face f (role-face sr))))
    (vector-set! out i f))
  out)

(define (color->faces cs)
  (for/list ([syntax (in-list (color-syntax-roles cs))]
             [word (in-list (color-word-roles cs))]
             [bracket (in-list (color-bracket-roles cs))])
    (combine-line syntax word bracket)))

;; core change -> lang 的行级编辑描述。
(define (changes->line-edits changes)
  (for/list ([ch (in-list changes)])
    (define b (change-before ch))
    (define a (change-after ch))
    (line-edit (point-line (range-start b))
               (point-line (range-end b))
               (point-line (range-start a))
               (point-line (range-end a)))))

(define (changes-for-doc pending did)
  (for/list ([dc (in-list pending)]
             #:when (equal? (doc-change-doc-id dc) did))
    dc))

;; 消费已经回来的 worker 结果。只有 result.version == 当前 engine version 才接受；
;; 过期结果只清除 pending 标记，让下一帧能重新请求当前版本。
(define (apply-pending-result old-entry result version)
  (cond
    [(not result) old-entry]
    [(equal? (color-result-version result) version)
     (if (and old-entry
              (equal? (color-entry-version old-entry) version))
         old-entry
         (color-entry version
                      (color-result-state result)
                      (color-result-faces result)
                      #f))]
    [else
     ;; 过期结果不能拿来和当前文本对齐。保留旧 faces 供显示，但丢掉旧 state /
     ;; pending，让 entry-sync 重新走全量，而不是误用单个 change 做增量。
     (if (and old-entry
              (equal? (color-entry-pending-version old-entry)
                      (color-result-version result)))
         (struct-copy color-entry old-entry
                      [pending-version #f]
                      [state #f])
         old-entry)]))

;; 返回 (values entry' state')；state' 可能因为提交 job 而变化。
(define (entry-sync state old did version text doc-changes)
  (cond
    ;; 已经是最新版本，且没有 outstanding job。
    [(and old
          (not (color-entry-pending-version old))
          (equal? (color-entry-version old) version))
     (values old state)]

    ;; 一次只允许一个全量 job；等它回来后再决定是否重发。
    [(and old (color-entry-pending-version old))
     (values old state)]

    ;; 有旧 state、且只有一个 change 正好到当前版本：主线程增量。
    [(and old
          (color-entry-state old)
          (= (length doc-changes) 1)
          (equal? (doc-change-version (car doc-changes)) version))
     (define cs (color-edit (color-entry-state old)
                            text
                            (changes->line-edits
                             (doc-change-changes (car doc-changes)))))
     (values (color-entry version cs (color->faces cs) #f) state)]

    ;; 首次打开 / undo-redo / 批量修改：后台全量。
    [else
     (define-values (state* _job)
       (app-state-submit-job state 'color-open
                             (list 'color-open did version text)
                             did))
     (define base (or old (color-entry #f #f '() #f)))
     (values (struct-copy color-entry base [pending-version version])
             state*)]))

;; 对当前打开的所有 resource 做颜色同步。
;; 返回新 state（改颜色缓存 / results / jobs）；engine 写 face 是派生副作用。
(define (sync-editor-colors! state engine)
  (define store (app-state-resources state))
  (define pending (app-state-pending-doc-changes state))
  (define old-colors
    (hash-ref (app-state-store state) editor-color-cache-key (hash)))
  (define old-results
    (hash-ref (app-state-store state) editor-color-result-key (hash)))

  (define-values (new-colors state*)
    (for/fold ([colors (hash)] [st state])
              ([r (in-list (resource-list store))])
      (define did (resource-doc-id r))
      (define path (resource-path store (resource-id r)))
      (define text (and did (engine-doc-text engine did)))
      (cond
        [(not (and did text)) (values colors st)]
        [else
         (define version (engine-doc-version engine did))
         (define views (resource-views r))
         (cond
           [(racket-doc? path text)
            (define old-entry (hash-ref old-colors did #f))
            (define result (hash-ref old-results did #f))
            (define entry0 (apply-pending-result old-entry result version))
            (define-values (entry st*)
              (entry-sync st entry0 did version text
                          (changes-for-doc pending did)))
            ;; 只应用属于当前 document version 的 attribute track。
            ;; 后台结果还没回来时，当前文档继续使用它自己的旧 face track，
            ;; 不把旧版本的 face 强行贴到新文本上。
            (when (equal? (color-entry-version entry) version)
              (for ([vid (in-list views)])
                (engine-set-view-faces! engine vid
                                        (color-entry-faces entry)
                                        #:base-version version
                                        #:key (list did version 'racket))))
            (values (hash-set colors did entry) st*)]
           [else
            ;; 非 Racket 文档也要清掉可能从 save-as 前留下的 face。
            (for ([vid (in-list views)])
              (engine-set-view-faces! engine vid
                                      '()
                                      #:base-version version
                                      #:key (list did version 'none)))
            (values colors st)])])))

  (struct-copy app-state state*
               [store (hash-set (hash-set (app-state-store state*)
                                          editor-color-cache-key new-colors)
                                editor-color-result-key
                                (hash))]))

;;; ════════════════ 后台 service / result ════════════════

(define (color-open-service payload)
  (match-define (list 'color-open did version text) payload)
  (define cs (color-open text))
  (color-result did version cs (color->faces cs)))

(define color-services
  (list (service 'color-open color-open-service)))

;; run-loop / demo 在 job-finish 之后调用。只把纯结果放进 results 暂存区；
;; 真正的版本校验在 sync（能拿到 engine 当前 version）里做。
(define (handle-color-job-result state ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'color-open)) state]
    [else
     (define result (job-result-event-result ev))
     (cond
       [(not (color-result? result)) state]
       [else
        (define results
          (hash-ref (app-state-store state) editor-color-result-key (hash)))
        (struct-copy app-state state
                     [store (hash-set (app-state-store state)
                                      editor-color-result-key
                                      (hash-set results
                                                (color-result-did result)
                                                result))])])]))

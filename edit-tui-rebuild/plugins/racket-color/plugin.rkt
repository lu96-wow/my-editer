#lang racket

;;; edit-tui-rebuild/plugins/racket-color/plugin.rkt —— Racket 语法着色
;;;
;;; 两条路径：
;;;   · changes derive：有 change 批次时用 color-edit* 只重扫脏行，写 dirty face lines；
;;;   · sync：版本变化但没有 changes（首次打开 / undo / 批量写回）时整篇 color-open，
;;;           并给新 view 写完整 face track。
;;;
;;; 非 Racket 文档完全不碰 face track，避免清掉 filetree / status 自己的 face。

(require racket/string
         "../../editor/api.rkt"
         "../../../edit-tui/lang/racket/api.rkt"
         "../../../edit-tui/core/face/api.rkt")

(provide racket-color-plugin
         (struct-out color-entry))

(struct color-entry
  (version
   color-state
   face-track)
  #:transparent)

(define empty-color-cache (hash))

;;; ════════════════ role -> face ════════════════

(define (bracket-role? role)
  (and role
       (string-prefix? (symbol->string role) "bracket-depth-")))

(define (role->face-layer role)
  (if (bracket-role? role)
      (face #f role '())
      (face role #f '())))

(define (role-at roles i)
  (and roles
       (< i (vector-length roles))
       (vector-ref roles i)))

(define (line->faces syntax word bracket)
  (define n (vector-length syntax))
  (for/vector ([i (in-range n)])
    (define f #f)
    (define br (role-at bracket i))
    (when br (set! f (compose-face f (role->face-layer br))))
    (define wr (role-at word i))
    (when wr (set! f (compose-face f (role->face-layer wr))))
    (define sr (role-at syntax i))
    (when sr (set! f (compose-face f (role->face-layer sr))))
    f))

(define (color-state->face-track cs)
  (for/list ([syntax (in-vector (color-state-syntax-roles cs))]
             [word (in-vector (color-state-word-roles cs))]
             [bracket (in-vector (color-state-bracket-roles cs))])
    (line->faces syntax word bracket)))

(define (color-state->dirty-face-lines cs dirty-lines)
  (define syntax (color-state-syntax-roles cs))
  (define word (color-state-word-roles cs))
  (define bracket (color-state-bracket-roles cs))
  (for/list ([ln (in-list dirty-lines)])
    (cons ln (line->faces (vector-ref syntax ln)
                          (vector-ref word ln)
                          (vector-ref bracket ln)))))

;;; ════════════════ changes -> line-edit ════════════════

(define (changes->line-edits changes)
  (for/list ([ch (in-list changes)])
    (define before (change-before ch))
    (define after (change-after ch))
    (line-edit (point-line (range-start before))
               (point-line (range-end before))
               (point-line (range-start after))
               (point-line (range-end after)))))

;;; ════════════════ 写回 ════════════════

(define (write-full-track! engine did version vids entry)
  (define key (list did version 'racket-color))
  (for ([vid (in-list vids)])
    (engine-set-view-face-track! engine vid (color-entry-face-track entry)
                                 #:base-version version
                                 #:key key)))

(define (write-dirty-lines! engine did version vids cs dirty)
  (define key (list did version 'racket-color))
  (define lines (color-state->dirty-face-lines cs dirty))
  (for ([vid (in-list vids)])
    (engine-set-view-face-lines! engine vid lines
                                 #:base-version version
                                 #:key key)))

;;; ════════════════ changes hook ════════════════

(define (changes-color ctx ps)
  (define engine (change-context-engine ctx))
  (define did (change-context-doc-id ctx))
  (define base-version (change-context-base-version ctx))
  (define version (change-context-version ctx))
  (define changes (change-context-changes ctx))
  (define text (engine-doc-text engine did))
  (cond
    [(or (not text) (not (racket-text? text)))
     (values ctx ps '() #t)]
    [else
     (define old (hash-ref ps did #f))
     (define-values (cs dirty)
       (cond
         [(and old (equal? (color-entry-version old) base-version))
          (color-edit* (color-entry-color-state old)
                       text
                       (changes->line-edits changes))]
         [else
          (values (color-open text) 'all)]))
     (define entry (color-entry version cs (color-state->face-track cs)))
     (define vids (engine-view-ids-for-doc engine did))
     (cond
       [(eq? dirty 'all)
        (write-full-track! engine did version vids entry)]
       [else
        (when (pair? dirty)
          (write-dirty-lines! engine did version vids cs dirty))])
     (values ctx (hash-set ps did entry) '() #t)]))

;;; ════════════════ sync ════════════════

(define (sync-colors ed state)
  (define engine (editor-engine ed))
  (define old-cache
    (or (editor-state-plugin-state state 'racket-color) empty-color-cache))
  (define (sync-doc cache did)
    (define text (engine-doc-text engine did))
    (define version (engine-doc-version engine did))
    (cond
      [(or (not text) (not version)) cache]
      [(not (racket-text? text)) cache]
      [else
       (define vids (engine-view-ids-for-doc engine did))
       (define cached (hash-ref old-cache did #f))
       (define entry
         (if (and cached (equal? (color-entry-version cached) version))
             cached
             (let ([cs (color-open text)])
               (color-entry version cs (color-state->face-track cs)))))
       (write-full-track! engine did version vids entry)
       (hash-set cache did entry)]))
  (define new-cache
    (for/fold ([cache (hash)]) ([did (in-list (engine-doc-ids engine))])
      (sync-doc cache did)))
  (editor-state-set-plugin-state state 'racket-color new-cache))

(define racket-color-plugin
  (make-plugin
   #:id 'racket-color
   #:state empty-color-cache
   #:hooks
   (list
    (make-hook #:owner 'racket-color
               #:id 'incremental-color
               #:operation 'changes
               #:phase 'derive
               #:fn changes-color))
   #:sync sync-colors))

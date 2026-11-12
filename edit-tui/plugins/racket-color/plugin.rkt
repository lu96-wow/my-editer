#lang racket

;;; edit-tui/plugins/racket-color/plugin.rkt —— Racket 语法着色
;;;
;;; 两条路径：
;;;   · changes derive：有 change 批次时用 color-edit* 只重扫脏行，写 dirty face lines；
;;;   · sync：版本变化但没有 changes（首次打开 / undo / 批量写回）时整篇 color-open，
;;;           并给新 view 写完整 face track。
;;;
;;; 非 Racket 文档完全不碰 face track，避免清掉 filetree / status 自己的 face。

(require racket/string
         "../../editor/api.rkt"
         "../../compat/lang/racket/api.rkt"
         "../../compat/face/api.rkt")

(provide racket-color-plugin
         (struct-out color-entry))

(struct color-entry
  (version
   color-state
   face-track)
  #:transparent)

(define empty-color-cache (hash))

;; 优先看 resource mode；没有 resource 的临时测试文档才退回文本判断。
(define (racket-doc? state did text)
  (or (eq? (state-doc-mode state did) 'racket)
      (and (not (state-resource-for-doc state did))
           (racket-text? text))))

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

(define (line->faces syntax word bracket
                     [suppress-start #f] [suppress-end #f])
  (define n (vector-length syntax))
  (for/vector ([i (in-range n)])
    (define f #f)
    (define br (role-at bracket i))
    (when br (set! f (compose-face f (role->face-layer br))))
    (define suppressed?
      (and suppress-start suppress-end
           (>= i suppress-start) (< i suppress-end)))
    (define wr (and (not suppressed?) (role-at word i)))
    (when wr (set! f (compose-face f (role->face-layer wr))))
    (define sr (role-at syntax i))
    (when sr (set! f (compose-face f (role->face-layer sr))))
    f))

;; suppress = (cons line (cons start end)) | #f
(define (color-state->face-track cs suppress)
  (define sl (and suppress (car suppress)))
  (define sr (and suppress (cdr suppress)))
  (for/list ([syntax (in-vector (color-state-syntax-roles cs))]
             [word (in-vector (color-state-word-roles cs))]
             [bracket (in-vector (color-state-bracket-roles cs))]
             [ln (in-naturals)])
    (if (and sl (= ln sl))
        (line->faces syntax word bracket (car sr) (cdr sr))
        (line->faces syntax word bracket))))

(define (color-state->dirty-face-lines cs dirty-lines suppress)
  (define syntax (color-state-syntax-roles cs))
  (define word (color-state-word-roles cs))
  (define bracket (color-state-bracket-roles cs))
  (define sl (and suppress (car suppress)))
  (define sr (and suppress (cdr suppress)))
  (for/list ([ln (in-list dirty-lines)])
    (cons ln (if (and sl (= ln sl))
                 (line->faces (vector-ref syntax ln) (vector-ref word ln)
                              (vector-ref bracket ln) (car sr) (cdr sr))
                 (line->faces (vector-ref syntax ln) (vector-ref word ln)
                              (vector-ref bracket ln))))))

;; 光标所在 symbol token 的 [start,end)。
(define (active-word-range cs line col)
  (define role-vectors (color-state-word-roles cs))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (vector-length role-vectors)))
     #f]
    [else
     (define roles (vector-ref role-vectors line))
     (define n (vector-length roles))
     (define idx
       (cond
         [(and (< col n) (vector-ref roles col)) col]
         [(and (> col 0) (<= col n) (vector-ref roles (sub1 col))) (sub1 col)]
         [else #f]))
     (cond
       [(not idx) #f]
       [else
        (define role (vector-ref roles idx))
        (define start
          (let loop ([i idx])
            (if (and (> i 0) (equal? (vector-ref roles (sub1 i)) role))
                (loop (sub1 i))
                i)))
        (define end
          (let loop ([i (add1 idx)])
            (if (and (< i n) (equal? (vector-ref roles i) role))
                (loop (add1 i))
                i)))
        (cons start end)])]))

;; 焦点 view 是否属于 doc；属于才抑制该行的 word-color。
(define (focus-suppress ed state did cs)
  (define vid (editor-focus-view-id state))
  (define fdid (and vid (editor-view-doc-id ed vid)))
  (cond
    [(not (equal? fdid did)) #f]
    [else
     (define line (editor-view-point-line ed vid))
     (define col (editor-view-point-column ed vid))
     (define range (and line col (active-word-range cs line col)))
     (and range (cons line range))]))

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

(define (write-full-track! ed did version vids entry suppress)
  (define key (list did version 'racket-color suppress))
  (define track
    (if suppress
        (color-state->face-track (color-entry-color-state entry) suppress)
        (color-entry-face-track entry)))
  (for ([vid (in-list vids)])
    (editor-set-view-face-track! ed vid track
                                 #:base-version version
                                 #:key key)))

(define (write-dirty-lines! ed did version vids cs dirty suppress)
  (define key (list did version 'racket-color suppress))
  (define lines (color-state->dirty-face-lines cs dirty suppress))
  (for ([vid (in-list vids)])
    (editor-set-view-face-lines! ed vid lines
                                 #:base-version version
                                 #:key key)))

;;; ════════════════ changes hook ════════════════

(define (changes-color ctx ps)
  (define ed (change-context-editor ctx))
  (define did (change-context-doc-id ctx))
  (define base-version (change-context-base-version ctx))
  (define version (change-context-version ctx))
  (define changes (change-context-changes ctx))
  (define text (editor-doc-text ed did))
  (cond
    [(or (not text) (not (racket-doc? (change-context-state ctx) did text)))
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
     (define entry (color-entry version cs (color-state->face-track cs #f)))
     (define suppress (focus-suppress ed (change-context-state ctx) did cs))
     (define vids (editor-view-ids-for-doc ed did))
     (cond
       [(eq? dirty 'all)
        (write-full-track! ed did version vids entry suppress)]
       [else
        (when (pair? dirty)
          (write-dirty-lines! ed did version vids cs dirty suppress))])
     (values ctx (hash-set ps did entry) '() #t)]))

;;; ════════════════ sync ════════════════

(define (sync-colors ed state ps)
  (define old-cache (if (hash? ps) ps empty-color-cache))
  (define (sync-doc cache did)
    (define text (editor-doc-text ed did))
    (define version (editor-doc-version ed did))
    (cond
      [(or (not text) (not version)) cache]
      [(not (racket-doc? state did text)) cache]
      [else
       (define vids (editor-view-ids-for-doc ed did))
       (define cached (hash-ref old-cache did #f))
       (define entry
         (if (and cached (equal? (color-entry-version cached) version))
             cached
             (let ([cs (color-open text)])
               (color-entry version cs (color-state->face-track cs #f)))))
       (define suppress (focus-suppress ed state did
                                       (color-entry-color-state entry)))
       (write-full-track! ed did version vids entry suppress)
       (hash-set cache did entry)]))
  (define new-cache
    (for/fold ([cache (hash)]) ([did (in-list (editor-user-doc-ids ed))])
      (sync-doc cache did)))
  (values state new-cache))

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

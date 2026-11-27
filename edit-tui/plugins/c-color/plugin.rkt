#lang racket

;;; edit-tui/plugins/c-color/plugin.rkt —— C 语法着色
;;;
;;; 两条路径：
;;;   · sync（headless / 测试）：changes 按行增量重扫脏行，sync 全量重扫。
;;;   · async（TUI）：face worker 内计算 color-state，一次 swap 写完整 face track，
;;;     再发 paint signal；主线程只记已提交版本。
;;;
;;; 只处理 mode = 'c 的 user doc；其它文档完全不碰 face track。

(require "../../editor/api.rkt"
         "../../lang/c/api.rkt"
         "../../core/face/api.rkt")

(provide c-color-plugin
         (struct-out c-color-entry))

(struct c-color-entry
  (version
   color-state)
  #:transparent)

;; async 路径只记已提交版本；color-state 在 face worker 内按 buffer 缓存。
(struct c-color-request (version) #:transparent)
(struct c-color-worker-entry (version color-state) #:transparent)

(define empty-c-color-cache (hash))
(define c-color-worker-cache (make-ephemeron-hasheq))

(define (c-doc? state did lines)
  (and lines
       (eq? (state-doc-mode state did) 'c)))

;;; ════════════════ role -> face ════════════════

(define (role->face role)
  (and role (face role #f '())))

(define (roles->face-line roles)
  (for/vector ([r (in-vector roles)])
    (role->face r)))

(define (color-state->face-track cs)
  (for/list ([roles (in-list (c-color-syntax-roles cs))])
    (roles->face-line roles)))

(define (color-state->dirty-face-lines cs dirty-lines)
  (define role-lines (list->vector (c-color-syntax-roles cs)))
  (for/list ([ln (in-list dirty-lines)]
             #:when (< ln (vector-length role-lines)))
    (cons ln (roles->face-line (vector-ref role-lines ln)))))

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

(define (write-full-track! ed did version vids cs)
  (define key (list did version 'c-color))
  (define track (color-state->face-track cs))
  (for ([vid (in-list vids)])
    (editor-set-view-face-track! ed vid track
                                 #:base-version version
                                 #:key key)))

(define (write-dirty-lines! ed did version vids cs dirty)
  (define key (list did version 'c-color))
  (define lines (color-state->dirty-face-lines cs dirty))
  (for ([vid (in-list vids)])
    (editor-set-view-face-lines! ed vid lines
                                 #:base-version version
                                 #:key key)))

;;; ════════════════ 后台 face worker ════════════════

(define (c-worker-color-state old lines version base-version changes kind)
  (cond
    [(and old (equal? (c-color-worker-entry-version old) version))
     (c-color-worker-entry-color-state old)]
    [(and (eq? kind 'edit)
          old
          (equal? (c-color-worker-entry-version old) base-version))
     (define-values (cs _dirty)
       (c-color-edit*/lines (c-color-worker-entry-color-state old)
                            lines
                            (changes->line-edits changes)))
     cs]
    [else (c-color-open-lines lines)]))

(define (c-color-worker-job! target lines version base-version changes kind)
  (define buffer (face-target-buffer target))
  (define old (hash-ref c-color-worker-cache buffer #f))
  (define cs (c-worker-color-state old lines version base-version
                                  changes kind))
  (face-target-set-face-lines! target (color-state->face-track cs))
  (hash-set! c-color-worker-cache buffer
             (c-color-worker-entry version cs)))

;;; ════════════════ changes hook ════════════════

(define (changes-color ctx ps)
  (define ed (change-context-editor ctx))
  (define state (change-context-state ctx))
  (define did (change-context-doc-id ctx))
  (define base-version (change-context-base-version ctx))
  (define version (change-context-version ctx))
  (define changes (change-context-changes ctx))
  (define lines (editor-doc-lines ed did))
  (cond
    [(or (not (eq? (editor-doc-kind ed did) 'user))
         (not (c-doc? state did lines)))
     (values ctx ps '() #t)]
    [(state-async? state)
     (define target (editor-doc-face-target ed did))
     (cond
       [(not target) (values ctx (hash-remove ps did) '() #t)]
       [else
        (define buffer (face-target-buffer target))
        (face-submit! buffer
                      (λ ()
                        (c-color-worker-job! target lines version base-version
                                             changes 'edit)))
        (values ctx (hash-set ps did (c-color-request version)) '() #t)])]
    [else
     (define old (hash-ref ps did #f))
     (define-values (cs dirty)
       (cond
         [(and old (equal? (c-color-entry-version old) base-version))
          (c-color-edit*/lines (c-color-entry-color-state old)
                               lines
                               (changes->line-edits changes))]
         [else
          (values (c-color-open-lines lines) 'all)]))
     (define entry (c-color-entry version cs))
     (define vids (or (editor-view-ids-for-doc ed did) '()))
     (cond
       [(eq? dirty 'all)
        (write-full-track! ed did version vids cs)]
       [(pair? dirty)
        (write-dirty-lines! ed did version vids cs dirty)]
       [else (void)])
     (values ctx (hash-set ps did entry) '() #t)]))

;;; ════════════════ sync ════════════════

(define (sync-colors ed state ps)
  (cond
    [(state-async? state)
     (define ps*
       (for/fold ([ps ps]) ([did (in-list (editor-user-doc-ids ed))])
         (define lines (editor-doc-lines ed did))
         (define version (editor-doc-version ed did))
         (define target (and lines version (editor-doc-face-target ed did)))
         (cond
           [(or (not lines)
                (not version)
                (not target)
                (not (c-doc? state did lines)))
            (hash-remove ps did)]
           [else
            (define req (hash-ref ps did #f))
            (cond
              [(and (c-color-request? req)
                    (equal? (c-color-request-version req) version))
               ps]
              [else
               (define buffer (face-target-buffer target))
               (face-submit! buffer
                             (λ ()
                               (c-color-worker-job! target lines version #f
                                                    '() 'sync)))
               (hash-set ps did (c-color-request version))])])))
     (values state ps*)]
    [else
     (define old-cache (if (hash? ps) ps empty-c-color-cache))
     (define (sync-doc cache did)
       (define lines (editor-doc-lines ed did))
       (define version (editor-doc-version ed did))
       (define vids (or (editor-view-ids-for-doc ed did) '()))
       (cond
         [(or (not lines) (not version) (null? vids)) cache]
         [(not (c-doc? state did lines)) cache]
         [else
          (define cached (hash-ref old-cache did #f))
          (define entry
            (if (and cached (equal? (c-color-entry-version cached) version))
                cached
                (c-color-entry version (c-color-open-lines lines))))
          (write-full-track! ed did version vids
                             (c-color-entry-color-state entry))
          (hash-set cache did entry)]))
     (define new-cache
       (for/fold ([cache (hash)]) ([did (in-list (editor-user-doc-ids ed))])
         (sync-doc cache did)))
     (values state new-cache)]))

(define c-color-plugin
  (make-plugin
   #:id 'c-color
   #:state empty-c-color-cache
   #:hooks
   (list
    (make-hook #:owner 'c-color
               #:id 'c-incremental-color
               #:operation 'changes
               #:phase 'derive
               #:fn changes-color))
   #:sync sync-colors))

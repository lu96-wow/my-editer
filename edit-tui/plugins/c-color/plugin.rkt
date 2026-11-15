#lang racket

;;; edit-tui/plugins/c-color/plugin.rkt —— C 语法着色
;;;
;;; 两条路径：
;;;   · changes derive：按行增量重扫脏行；
;;;   · sync：版本变化但没有 changes（首次打开 / undo / 整篇写回）时全量重扫。
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

(define empty-c-color-cache (hash))

(define (c-doc? state did text)
  (and text
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

;;; ════════════════ changes hook ════════════════

(define (changes-color ctx ps)
  (define ed (change-context-editor ctx))
  (define did (change-context-doc-id ctx))
  (define base-version (change-context-base-version ctx))
  (define version (change-context-version ctx))
  (define changes (change-context-changes ctx))
  (define text (editor-doc-text ed did))
  (cond
    [(or (not (eq? (editor-doc-kind ed did) 'user))
         (not (c-doc? (change-context-state ctx) did text)))
     (values ctx ps '() #t)]
    [else
     (define old (hash-ref ps did #f))
     (define-values (cs dirty)
       (cond
         [(and old (equal? (c-color-entry-version old) base-version))
          (c-color-edit* (c-color-entry-color-state old)
                         text
                         (changes->line-edits changes))]
         [else
          (values (c-color-open text) 'all)]))
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
  (define old-cache (if (hash? ps) ps empty-c-color-cache))
  (define (sync-doc cache did)
    (define text (editor-doc-text ed did))
    (define version (editor-doc-version ed did))
    (define vids (or (editor-view-ids-for-doc ed did) '()))
    (cond
      [(or (not text) (not version) (null? vids)) cache]
      [(not (c-doc? state did text)) cache]
      [else
       (define cached (hash-ref old-cache did #f))
       (define entry
         (if (and cached (equal? (c-color-entry-version cached) version))
             cached
             (c-color-entry version (c-color-open text))))
       (write-full-track! ed did version vids
                          (c-color-entry-color-state entry))
       (hash-set cache did entry)]))
  (define new-cache
    (for/fold ([cache (hash)]) ([did (in-list (editor-user-doc-ids ed))])
      (sync-doc cache did)))
  (values state new-cache))

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

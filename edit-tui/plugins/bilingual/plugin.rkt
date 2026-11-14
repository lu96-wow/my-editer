#lang racket

;;; edit-tui/plugins/bilingual/plugin.rkt —— 双语编程原型
;;;
;;; 模型：
;;;   source user doc       权威文本
;;;   mirror derived doc    纯内存投影，可被用户编辑（intent）
;;;
;;; 源变化 -> derived-content 投影（不产生 changes）
;;; 镜像变化 -> action -> host 用 editor-replace-lines! 写回源
;;; 源写入后再次投影，循环终止。
;;;
;;; 镜像没有 history；undo 只在源 buffer 生效。

(require (only-in racket/list take drop)
         "../../core/command/api.rkt"
         "../../editor/api.rkt"
         "action.rkt"
         "api.rkt"
         "model.rkt")

(provide bilingual-plugin)

;;; ════════════════ 行操作 ════════════════

(define (slice xs start end)
  (take (drop xs start) (- end start)))

(define (flash-message state text)
  (values state (list (flash-action text))))

(define (pair-translator ps p)
  (state-translator ps (pair-translator-id p)))

;;; ════════════════ 源 -> 镜像投影 ════════════════

(define (project-source-changes ctx ps)
  (define ed (change-context-editor ctx))
  (define state (change-context-state ctx))
  (define did (change-context-doc-id ctx))
  (define p (pair-for-source ps did))
  (cond
    [(or (not p) (not (eq? (editor-doc-kind ed did) 'user)))
     (values ctx ps '() #t)]
    [else
     (define tr (pair-translator ps p))
     (cond
       [(not tr) (values ctx ps '() #t)]
       [else
        (define new-source-lines
          (split-lines (editor-doc-text ed did)))
        (define old-source-lines (pair-source-lines p))
        (define old-mirror-lines (pair-mirror-lines p))
        (define-values (os0 oe0 ns0 ne0)
          (line-diff old-source-lines new-source-lines))
        ;; 1:1 行映射不变式被破坏时，退回整篇重投影，避免错位替换。
        (define-values (os oe ns ne)
          (if (= (length old-mirror-lines) (length old-source-lines))
              (values os0 oe0 ns0 ne0)
              (values 0 (length old-mirror-lines) 0 (length new-source-lines))))
        (define translated
          (for/list ([line (in-list (slice new-source-lines ns ne))])
            ((translator-translate-line tr) line)))
        (define new-mirror-lines
          (append (take old-mirror-lines os)
                  translated
                  (drop old-mirror-lines oe)))
        (void (editor-set-derived-view-content!
               ed (pair-mirror-view-id p)
               new-mirror-lines
               (make-list (length new-mirror-lines) 'bilingual-mirror-line)))
        (define p*
          (struct-copy pair p
                       [translator-version (translator-version tr)]
                       [source-version (editor-doc-version ed did)]
                       [mirror-version (editor-doc-version ed
                                                          (pair-mirror-doc-id p))]
                       [source-lines new-source-lines]
                       [mirror-lines new-mirror-lines]))
        (values ctx (state-set-pair ps p*) '() #t)])]))

;;; ════════════════ 镜像 -> 源反译 ════════════════

(define (capture-mirror-changes ctx ps)
  (define ed (change-context-editor ctx))
  (define did (change-context-doc-id ctx))
  (define p (pair-for-mirror ps did))
  (cond
    [(or (not p) (not (eq? (editor-doc-kind ed did) 'derived)))
     (values ctx ps '() #t)]
    [else
     (define tr (pair-translator ps p))
     (cond
       [(not tr)
        (values ctx ps (list (flash-action "bilingual: translator missing")) #t)]
       [else
        (define new-mirror-lines
          (split-lines (editor-doc-text ed did)))
        (define old-mirror-lines (pair-mirror-lines p))
        (define-values (os oe ns ne)
          (line-diff old-mirror-lines new-mirror-lines))
        (cond
          [(not (= (length old-mirror-lines) (length (pair-source-lines p))))
           (values ctx ps
                   (list (flash-action "bilingual: pair out of sync"))
                   #t)]
          [(and (= os oe) (= ns ne))
           (values ctx ps '() #t)]
          [else
           (define changed (slice new-mirror-lines ns ne))
           (define inverse
             (for/list ([line (in-list changed)])
               ((translator-inverse-line tr) line)))
           (cond
             [(ormap (lambda (x) (not x)) inverse)
              (values ctx ps
                      (list (flash-action "bilingual: inverse translation failed"))
                      #t)]
             [else
              (values ctx ps
                      (list (bilingual-replace-source-action
                             (pair-source-doc-id p)
                             os oe inverse))
                      #t)])])])]))

;;; ════════════════ viewport 行列同步 ════════════════

(define (view-anchor ed vid)
  (define p (editor-view-anchor-point ed vid))
  (and p (cons (point-line p) (point-column p))))

(define (view-line-text ed vid line)
  (define text (editor-view-text ed vid))
  (and text
       (let ([lines (split-lines text)])
         (and (< line (length lines))
              (list-ref lines line)))))

;; 行同步：leader 的 anchor line 原样给 follower。
;; 列同步：按 leader 当前行长度比例映射到 follower 行长度。
(define (sync-viewport! ed leader-vid follower-vid)
  (define la (view-anchor ed leader-vid))
  (define leader-line-text
    (and la (view-line-text ed leader-vid (car la))))
  (define follower-text (editor-view-text ed follower-vid))
  (cond
    [(or (not la) (not leader-line-text) (not follower-text)) (void)]
    [else
     (define follower-lines (split-lines follower-text))
     (define line (min (car la) (sub1 (max 1 (length follower-lines)))))
     (define target-line-text (list-ref follower-lines line))
     (define leader-len (string-length leader-line-text))
     (define target-len (string-length target-line-text))
     (define col
       (if (zero? leader-len)
           0
           (min target-len
                (round (* (/ (cdr la) leader-len) target-len)))))
     (editor-set-view-anchor-point! ed follower-vid (point line col))]))

(define (source-view-id ed state p)
  (define source-doc-id (pair-source-doc-id p))
  (define fvid (editor-focus-view-id state))
  (cond
    [(and fvid (equal? (editor-view-doc-id ed fvid) source-doc-id)) fvid]
    [else
     (for/first ([vid (in-list (or (editor-view-ids-for-doc ed source-doc-id)
                                   '()))]
                 #:when (equal? (editor-view-doc-id ed vid) source-doc-id))
       vid)]))

;; 哪一边的 anchor 变了，哪一边就是 leader；两边同时变时用 focus 决定。
(define (sync-pair-viewport! ed state p ps)
  (define source-vid (source-view-id ed state p))
  (define mirror-vid (pair-mirror-view-id p))
  (cond
    [(or (not source-vid) (not mirror-vid)) ps]
    [else
     (define sa (view-anchor ed source-vid))
     (define ma (view-anchor ed mirror-vid))
     (define old-sa (pair-source-anchor p))
     (define old-ma (pair-mirror-anchor p))
     (define source-changed? (not (equal? sa old-sa)))
     (define mirror-changed? (not (equal? ma old-ma)))
     (define leader
       (cond
         [(and source-changed? (not mirror-changed?)) 'source]
         [(and mirror-changed? (not source-changed?)) 'mirror]
         [(and source-changed? mirror-changed?)
          (if (equal? (editor-focus-view-id state) mirror-vid)
              'mirror
              'source)]
         [else #f]))
     (when (eq? leader 'source)
       (sync-viewport! ed source-vid mirror-vid))
     (when (eq? leader 'mirror)
       (sync-viewport! ed mirror-vid source-vid))
     (define sa* (view-anchor ed source-vid))
     (define ma* (view-anchor ed mirror-vid))
     (if (and (equal? sa* old-sa) (equal? ma* old-ma))
         ps
         (state-set-pair
          ps
          (struct-copy pair p
                       [source-anchor sa*]
                       [mirror-anchor ma*])))]))

;;; ════════════════ 每帧兜底 ════════════════

(define (project-pair ed ps p)
  (define source-text
    (editor-doc-text ed (pair-source-doc-id p)))
  (define mirror-text
    (editor-doc-text ed (pair-mirror-doc-id p)))
  (define tr (pair-translator ps p))
  (cond
    [(or (not source-text) (not mirror-text) (not tr)) ps]
    [else
     (define source-lines (split-lines source-text))
     (define mirror-lines (split-lines mirror-text))
     (define source-changed?
       (not (equal? source-lines (pair-source-lines p))))
     (define translator-changed?
       (or (not (equal? (translator-id tr) (pair-translator-id p)))
           (not (equal? (translator-version tr)
                        (pair-translator-version p)))))
     (define mirror-diverged?
       (and (not source-changed?)
            (not (equal? mirror-lines (pair-mirror-lines p)))))
     (cond
       [(or source-changed? translator-changed? mirror-diverged?)
        (define new-mirror-lines
          (for/list ([line (in-list source-lines)])
            ((translator-translate-line tr) line)))
        (void (editor-set-derived-view-content!
               ed (pair-mirror-view-id p)
               new-mirror-lines
               (make-list (length new-mirror-lines) 'bilingual-mirror-line)))
        (define p*
          (struct-copy pair p
                       [translator-version (translator-version tr)]
                       [source-version (editor-doc-version ed
                                                          (pair-source-doc-id p))]
                       [mirror-version (editor-doc-version ed
                                                          (pair-mirror-doc-id p))]
                       [source-lines source-lines]
                       [mirror-lines new-mirror-lines]))
        (state-set-pair ps p*)]
       [else ps])]))

(define (sync-bilingual! ed state ps)
  (cond
    [(not (bilingual-state? ps)) (values state ps)]
    [else
     (define ps1
       (for/fold ([ps ps])
                 ([p (in-list (hash-values (bilingual-state-pairs ps)))])
         (project-pair ed ps p)))
     (define ps2
       (for/fold ([ps ps1])
                 ([p (in-list (hash-values (bilingual-state-pairs ps1)))])
         (sync-pair-viewport! ed state p ps)))
     (values state ps2)]))

;;; ════════════════ 命令 ════════════════

(define (toggle-bilingual-command ed state ps)
  (define vid (editor-focus-view-id state))
  (define did (and vid (editor-view-doc-id ed vid)))
  (cond
    [(not did) (flash-message state "bilingual: no focused view")]
    [else
     (define kind (editor-doc-kind ed did))
     (cond
       [(eq? kind 'user)
        (define p (pair-for-source ps did))
        (cond
          [p (values state ps
                     (list (bilingual-focus-action (pair-mirror-view-id p))))]
          [else
           (values state ps
                   (list (bilingual-open-action
                          did
                          (bilingual-default-translator-id ps))))])]
       [(eq? kind 'derived)
        (define p (pair-for-mirror ps did))
        (cond
          [p (values state ps
                     (list (bilingual-close-action (pair-source-doc-id p))))]
          [else (flash-message state "bilingual: mirror is not paired")])]
       [else (flash-message state "bilingual: not a text buffer")])]))

(define bilingual-plugin
  (make-plugin
   #:id 'bilingual
   #:state (empty-bilingual-state)
   #:hooks
   (list
    (make-hook #:owner 'bilingual
               #:id 'project-source
               #:operation 'changes
               #:phase 'derive
               #:priority 0
               #:fn project-source-changes)
    (make-hook #:owner 'bilingual
               #:id 'capture-mirror
               #:operation 'changes
               #:phase 'observe
               #:priority 0
               #:fn capture-mirror-changes))
   #:sync sync-bilingual!
   #:commands
   (keys
    [(key 'l 'alt) toggle-bilingual-command])))

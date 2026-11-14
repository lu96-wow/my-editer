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
         racket/match
         racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt"
         "action.rkt"
         "api.rkt"
         "lexicon.rkt"
         "model.rkt"
         "words.rkt"
         (only-in "translate.rkt"
                  default-translator
                  default-translator-id
                  translator-with-overrides))

(provide bilingual-plugin
         make-bilingual-plugin
         bilingual-request-word-translations!)

;;; ════════════════ 行操作 ════════════════

(define (slice xs start end)
  (take (drop xs start) (- end start)))

(define (spans->face-vector text spans)
  (define n (string-length text))
  (define v (make-vector n #f))
  (for ([span (in-list spans)])
    (define start (max 0 (car span)))
    (define end (min n (cadr span)))
    (define f (caddr span))
    (for ([i (in-range start end)])
      (vector-set! v i f)))
  v)

(define (translate-line+face tr line)
  (define-values (text spans) ((translator-translate-line+faces tr) line))
  (cons text (spans->face-vector text spans)))

(define (write-mirror! ed mirror-vid lines faces)
  ;; engine 根据 derived doc 级基线自动选择按行增量或 full fallback。
  (void (editor-set-derived-view-projection! ed mirror-vid lines faces)))

;; 用同一行号的新翻译替换 mirror 行；失败返回 #f。
(define (apply-retranslated-lines! ed p source-lines dirty-lines
                                  translated-lines translated-faces
                                  source-version tr-version)
  (define old-mirror-lines (pair-mirror-lines p))
  (define old-mirror-faces (pair-mirror-faces p))
  (define n (length old-mirror-lines))
  (cond
    [(or (not (= (length old-mirror-faces) n))
         (not (= (length source-lines) n))
         (not (= (length dirty-lines) (length translated-lines)))
         (not (= (length dirty-lines) (length translated-faces)))
         (for/or ([i (in-list dirty-lines)])
           (or (not (exact-nonnegative-integer? i))
               (>= i n))))
     #f]
    [else
     (define linesv (list->vector old-mirror-lines))
     (define facesv (list->vector old-mirror-faces))
     (for ([i (in-list dirty-lines)]
           [line (in-list translated-lines)]
           [face (in-list translated-faces)])
       (vector-set! linesv i line)
       (vector-set! facesv i face))
     (define new-mirror-lines (vector->list linesv))
     (define new-mirror-faces (vector->list facesv))
     (write-mirror! ed (pair-mirror-view-id p)
                    new-mirror-lines new-mirror-faces)
     (struct-copy pair p
                  [translator-version tr-version]
                  [source-version source-version]
                  [mirror-version (editor-doc-version
                                   ed (pair-mirror-doc-id p))]
                  [pending-version #f]
                  [pending-job-id #f]
                  [timer-id #f]
                  [source-lines source-lines]
                  [mirror-lines new-mirror-lines]
                  [mirror-faces new-mirror-faces])]))

(define (flash-message state text)
  (values state (list (flash-action text))))

(define (pair-translator ps p)
  (state-translator ps (pair-translator-id p)))

;;; ════════════════ 源 -> 镜像投影 ════════════════

(define debounce-ms 80)
(define translation-kind 'bilingual-translate)
(define edit-translation-kind 'bilingual-translate-edit)
(define word-translation-kind 'bilingual-word-translate)
(define retranslate-kind 'bilingual-retranslate-lines)
(define word-batch-limit 200)

;; 同步路径：headless / state-async? = #f 时使用。
(define (project-source-changes-sync ctx ps)
  (define ed (change-context-editor ctx))
  (define did (change-context-doc-id ctx))
  (define p (pair-for-source ps did))
  (cond
    [(not p) (values ctx ps '() #t)]
    [else
     (define tr (pair-translator ps p))
     (cond
       [(not tr) (values ctx ps '() #t)]
       [else
        (define new-source-lines
          (split-lines (editor-doc-text ed did)))
        (define old-source-lines (pair-source-lines p))
        (define old-mirror-lines (pair-mirror-lines p))
        (define old-mirror-faces (pair-mirror-faces p))
        (define-values (os0 oe0 ns0 ne0)
          (line-diff old-source-lines new-source-lines))
        ;; 1:1 行映射不变式 / face 基线不一致时，退回整篇重投影。
        (define same-shape?
          (and (= (length old-mirror-lines) (length old-source-lines))
               (= (length old-mirror-faces) (length old-mirror-lines))))
        (define-values (os oe ns ne)
          (if same-shape?
              (values os0 oe0 ns0 ne0)
              (values 0 0 0 (length new-source-lines))))
        (define base-faces (if same-shape? old-mirror-faces '()))
        (define translated-pairs
          (for/list ([line (in-list (slice new-source-lines ns ne))])
            (translate-line+face tr line)))
        (define translated (map car translated-pairs))
        (define translated-faces (map cdr translated-pairs))
        (define new-mirror-lines
          (append (take old-mirror-lines os)
                  translated
                  (drop old-mirror-lines oe)))
        (define new-mirror-faces
          (append (take base-faces os)
                  translated-faces
                  (drop base-faces oe)))
        (write-mirror! ed (pair-mirror-view-id p) new-mirror-lines new-mirror-faces)
        (define p*
          (struct-copy pair p
                       [translator-version (translator-version tr)]
                       [source-version (editor-doc-version ed did)]
                       [mirror-version (editor-doc-version ed
                                                          (pair-mirror-doc-id p))]
                       [pending-version #f]
                       [pending-job-id #f]
                       [timer-id #f]
                       [source-lines new-source-lines]
                       [mirror-lines new-mirror-lines]
                       [mirror-faces new-mirror-faces]))
        (values ctx (state-set-pair ps p*) '() #t)])]))

(define (schedule-projection-timer! ed p)
  (when (pair-timer-id p)
    (editor-cancel-timer! ed (pair-timer-id p)))
  (define tid (editor-schedule-timer! ed debounce-ms))
  (and tid
       (struct-copy pair p
                    [timer-id tid]
                    [pending-version (editor-doc-version
                                      ed (pair-source-doc-id p))])))

(define (project-source-changes ctx ps)
  (define ed (change-context-editor ctx))
  (define state (change-context-state ctx))
  (define did (change-context-doc-id ctx))
  (define p (pair-for-source ps did))
  (cond
    [(or (not p) (not (eq? (editor-doc-kind ed did) 'user)))
     (values ctx ps '() #t)]
    [(state-async? state)
     (define p* (schedule-projection-timer! ed p))
     (cond
       [p* (values ctx (state-set-pair ps p*) '() #t)]
       ;; 没有 timer service：退回同步，保证 headless 可用。
       [else (project-source-changes-sync ctx ps)])]
    [else (project-source-changes-sync ctx ps)]))

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

;;; ════════════════ 异步翻译 ════════════════

(define (clear-pending ps p)
  (state-set-pair
   ps
   (struct-copy pair p
                [pending-version #f]
                [pending-job-id #f])))

(define (submit-projection-job! ed state ps p #:force-full? [force-full? #f])
  (define source-doc-id (pair-source-doc-id p))
  (define version (editor-doc-version ed source-doc-id))
  (define text (editor-doc-text ed source-doc-id))
  (define tr (pair-translator ps p))
  (cond
    [(or (not version) (not text) (not tr))
     (values state (clear-pending ps (struct-copy pair p [timer-id #f])))]
    [(and (not force-full?)
          (equal? version (pair-source-version p)))
     ;; 源已回到上次安装的版本：不需要 job。
     (values state (clear-pending ps (struct-copy pair p [timer-id #f])))]
    [else
     (define tr-id (translator-id tr))
     (define tr-version (translator-version tr))
     (define source-lines (split-lines text))
     (define edit?
       (and (not force-full?)
            (not (null? (pair-source-lines p)))
            (= (length (pair-source-lines p))
               (length (pair-mirror-lines p)))
            (= (length (pair-mirror-faces p))
               (length (pair-mirror-lines p)))))
     (define kind (if edit? edit-translation-kind translation-kind))
     (define payload
       (if edit?
           (list source-doc-id version tr-id tr-version
                 (pair-source-lines p) source-lines tr)
           (list source-doc-id version tr-id tr-version text tr)))
     (define tag (list source-doc-id version tr-id tr-version))
     (define-values (state* job)
       (state-submit-job state kind payload tag))
     (define p*
       (struct-copy pair p
                    [translator-version tr-version]
                    [force-full? #f]
                    [timer-id #f]
                    [pending-version version]
                    [pending-job-id (job-id job)]))
     (values state* (state-set-pair ps p*))]))

(define (repair-mirror! ed ps p)
  (write-mirror! ed (pair-mirror-view-id p)
                 (pair-mirror-lines p) (pair-mirror-faces p))
  (state-set-pair
   ps
   (struct-copy pair p
                [mirror-version (editor-doc-version
                                 ed (pair-mirror-doc-id p))])))

(define (ensure-pair-async! ed state ps p)
  (define source-doc-id (pair-source-doc-id p))
  (define mirror-doc-id (pair-mirror-doc-id p))
  (define source-version (editor-doc-version ed source-doc-id))
  (define mirror-version (editor-doc-version ed mirror-doc-id))
  (define tr (pair-translator ps p))
  (define current-tr-version (and tr (translator-version tr)))
  (cond
    [(or (not source-version) (not mirror-version))
     (values state ps)]
    [(or (pair-force-full? p)
         (and current-tr-version
              (not (equal? current-tr-version (pair-translator-version p)))))
     (cond
       [(or (pair-timer-id p) (pair-pending-job-id p))
        (values state ps)]
       [else
        ;; 词典变了 / 手动要求 full，但之前没机会 patch：保守 full 重投影。
        (submit-projection-job! ed state ps p #:force-full? #t)])]
    [(not (equal? source-version (pair-source-version p)))
     (cond
       [(or (pair-timer-id p) (pair-pending-job-id p))
        (values state ps)]
       [else (submit-projection-job! ed state ps p)])]
    [(equal? mirror-version (pair-mirror-version p))
     (values state ps)]
    [else
     ;; 源没变、mirror 变了：反译失败或用户编辑未回源，按源权威恢复投影。
     (values state (repair-mirror! ed ps p))]))

;;; ════════════════ 同步兜底 ════════════════

(define (full-project-pair-sync ed ps p)
  (define source-text (editor-doc-text ed (pair-source-doc-id p)))
  (define tr (pair-translator ps p))
  (cond
    [(or (not source-text) (not tr)) ps]
    [else
     (define source-lines (split-lines source-text))
     (define translated-pairs
       (for/list ([line (in-list source-lines)])
         (translate-line+face tr line)))
     (define new-mirror-lines (map car translated-pairs))
     (define new-mirror-faces (map cdr translated-pairs))
     (write-mirror! ed (pair-mirror-view-id p)
                    new-mirror-lines new-mirror-faces)
     (state-set-pair
      ps
      (struct-copy pair p
                   [translator-version (translator-version tr)]
                   [force-full? #f]
                   [source-version (editor-doc-version ed
                                                      (pair-source-doc-id p))]
                   [mirror-version (editor-doc-version ed
                                                      (pair-mirror-doc-id p))]
                   [pending-version #f]
                   [pending-job-id #f]
                   [timer-id #f]
                   [source-lines source-lines]
                   [mirror-lines new-mirror-lines]
                   [mirror-faces new-mirror-faces]))]))

(define (project-pair-sync ed ps p)
  (define source-doc-id (pair-source-doc-id p))
  (define mirror-doc-id (pair-mirror-doc-id p))
  (define source-version (editor-doc-version ed source-doc-id))
  (define mirror-version (editor-doc-version ed mirror-doc-id))
  (define tr (pair-translator ps p))
  (cond
    [(or (not source-version) (not mirror-version)) ps]
    [(or (pair-force-full? p)
         (and tr
              (not (equal? (translator-version tr)
                           (pair-translator-version p)))))
     (full-project-pair-sync ed ps p)]
    [(and (equal? source-version (pair-source-version p))
          (equal? mirror-version (pair-mirror-version p)))
     ps]
    [(and (equal? source-version (pair-source-version p))
          (not (equal? mirror-version (pair-mirror-version p))))
     (repair-mirror! ed ps p)]
    [else (full-project-pair-sync ed ps p)]))

;;; ════════════════ job / timer handler ════════════════

(define (bilingual-translate-edit-service payload)
  (match-define (list source-doc-id version tr-id tr-version
                      old-lines new-lines tr)
    payload)
  (define-values (os oe ns ne) (line-diff old-lines new-lines))
  (define changed (slice new-lines ns ne))
  (define translated-pairs
    (for/list ([line (in-list changed)])
      (translate-line+face tr line)))
  (list source-doc-id version tr-id tr-version
        os oe ns ne
        new-lines
        (map car translated-pairs)
        (map cdr translated-pairs)))

(define (bilingual-translate-service payload)
  (define source-doc-id (list-ref payload 0))
  (define version (list-ref payload 1))
  (define tr-id (list-ref payload 2))
  (define tr-version (list-ref payload 3))
  (define text (list-ref payload 4))
  (define tr (list-ref payload 5))
  (cond
    [(not (translator? tr))
     (job-error (format "bilingual: unknown translator ~a" tr-id))]
    [else
     (define source-lines (split-lines text))
     (define translated-pairs
       (for/list ([line (in-list source-lines)])
         (translate-line+face tr line)))
     (list source-doc-id version tr-id tr-version
           source-lines
           (map car translated-pairs)
           (map cdr translated-pairs))]))

(define (pair-by-timer ps tid)
  (and (bilingual-state? ps)
       (for/first ([p (in-hash-values (bilingual-state-pairs ps))]
                   #:when (equal? (pair-timer-id p) tid))
         p)))

(define (handle-bilingual-timer ed state ps ev)
  (define p (pair-by-timer ps (timer-event-id ev)))
  (cond
    [(not p) (values state ps '())]
    [else
     (define p1 (struct-copy pair p [timer-id #f]))
     (define ps1 (state-set-pair ps p1))
     (define-values (state* ps*)
       (submit-projection-job! ed state ps1 p1
                               #:force-full? (pair-force-full? p1)))
     (values state* ps* '())]))

;;; ════════════════ 动态词翻译 ════════════════

(define (lexicon->translator lex)
  (define dynamic-inverse
    (for/hash ([(cn en) (in-hash (lexicon-inverse lex))])
      (values cn (cons en #f))))
  (translator-with-overrides
   default-translator
   (lexicon-forward lex)
   dynamic-inverse
   #:version (list (translator-version default-translator)
                   (lexicon-generation lex))))

(define (bilingual-retranslate-lines-service payload)
  (match-define (list source-doc-id version tr-id tr-version
                      source-lines dirty-lines tr)
    payload)
  (define translated-pairs
    (for/list ([i (in-list dirty-lines)])
      (translate-line+face tr (list-ref source-lines i))))
  (list source-doc-id version tr-id tr-version
        source-lines dirty-lines
        (map car translated-pairs)
        (map cdr translated-pairs)))

(define (submit-retranslate-lines-job! ed state ps p dirty-lines tr)
  (define source-doc-id (pair-source-doc-id p))
  (define version (editor-doc-version ed source-doc-id))
  (cond
    [(or (not version) (not tr) (null? dirty-lines))
     (values state ps)]
    [else
     (define tr-id (translator-id tr))
     (define tr-version (translator-version tr))
     (define source-lines (pair-source-lines p))
     (define payload
       (list source-doc-id version tr-id tr-version
             source-lines dirty-lines tr))
     (define-values (state* job)
       (state-submit-job state retranslate-kind
                         payload (list source-doc-id version)))
     (define p*
       (struct-copy pair p
                    [timer-id #f]
                    [pending-version version]
                    [pending-job-id (job-id job)]))
     (values state* (state-set-pair ps p*))]))

;; 词典加入新词后，只重译包含这些新词的 source 行。
(define (update-pairs-after-lexicon! ed state ps added new-tr)
  (define added-words
    (for/list ([entry (in-list added)]) (car entry)))
  (define new-version (translator-version new-tr))
  (for/fold ([state state] [ps ps])
            ([p (in-list (hash-values (bilingual-state-pairs ps)))])
    (cond
      [(not (equal? (pair-translator-id p) default-translator-id))
       (values state ps)]
      [else
       (define source-lines (pair-source-lines p))
       (define mirror-lines (pair-mirror-lines p))
       (define mirror-faces (pair-mirror-faces p))
       (define shape-ok?
         (and (not (null? source-lines))
              (= (length source-lines) (length mirror-lines))
              (= (length mirror-faces) (length mirror-lines))))
       (define dirty-lines
         (if shape-ok?
             (bilingual-lines-with-words source-lines added-words)
             '()))
       (cond
         ;; 已有 source/mirror job 在跑：先不动；之后由 translator-version
         ;; mismatch 走 full fallback。
         [(or (pair-timer-id p) (pair-pending-job-id p))
          (values state
                  (state-set-pair
                   ps (struct-copy pair p [force-full? #t])))]
         [(not shape-ok?)
          (values state
                  (state-set-pair
                   ps (struct-copy pair p [force-full? #t])))]
         [(null? dirty-lines)
          (values state
                  (state-set-pair
                   ps (struct-copy pair p [translator-version new-version])))]
         [(state-async? state)
          (submit-retranslate-lines-job! ed state ps p dirty-lines new-tr)]
         [else
          (define source-version
            (editor-doc-version ed (pair-source-doc-id p)))
          (define translated-pairs
            (for/list ([i (in-list dirty-lines)])
              (translate-line+face new-tr (list-ref source-lines i))))
          (define p*
            (apply-retranslated-lines!
             ed p source-lines dirty-lines
             (map car translated-pairs)
             (map cdr translated-pairs)
             source-version new-version))
          (values state
                  (state-set-pair
                   ps
                   (or p*
                       (struct-copy pair p
                                    [translator-version new-version]))))])])))

;; 先只提供显式请求入口；自动触发 / 命令键位后面再加。
;; → (values state' ps' actions)
(define (bilingual-request-word-translations! ed state ps)
  (cond
    [(not (bilingual-state? ps))
     (flash-message state "bilingual: plugin state missing")]
    [else
     (define lex (state-lexicon ps))
     (cond
       [(lexicon-job-id lex)
        (flash-message state "bilingual: word translation already running")]
       [else
        (define vid (editor-focus-view-id state))
        (define did (and vid (editor-view-doc-id ed vid)))
        (cond
          [(not did)
           (flash-message state "bilingual: no focused view")]
          [(not (eq? (editor-doc-kind ed did) 'user))
           (flash-message state "bilingual: focus is not a user document")]
          [else
           (define words (bilingual-word-candidates ed state did))
           (define known (translator-forward default-translator))
           (define unknown
             (for/list ([w (in-list words)]
                        #:unless (hash-has-key? known w)
                        #:unless (lexicon-known? lex w)
                        #:unless (lexicon-pending? lex w))
               w))
           (define batch
             (take unknown (min word-batch-limit (length unknown))))
           (cond
             [(null? batch)
              (flash-message state "bilingual: no new words")]
             [else
              (define lex1 (lexicon-add-pending lex batch))
              (define generation (lexicon-generation lex1))
              (define r (state-resource-for-doc state did))
              (define context
                (hash 'path (and r (resource-path r))
                      'lang 'racket))
              (define payload
                (list (translator-id default-translator)
                      generation batch context))
              (define-values (state* job)
                (state-submit-job state word-translation-kind
                                  payload
                                  (list (translator-id default-translator)
                                        generation)))
              (define lex2 (lexicon-set-job-id lex1 (job-id job)))
              (values
               (state-with-flash
                state*
                (format "bilingual: translating ~a words" (length batch)))
               (state-set-lexicon ps lex2)
               '())])])])]))

(define (handle-bilingual-word-job ed state ps ev)
  (define lex (state-lexicon ps))
  (cond
    [(not (equal? (lexicon-job-id lex) (job-result-event-id ev)))
     (values state ps '())]
    [else
     (define result (job-result-event-result ev))
     (define lex0
       (lexicon-set-job-id (lexicon-clear-all-pending lex) #f))
     (define ps0 (state-set-lexicon ps lex0))
     (cond
       [(job-error? result)
        (values
         (state-with-flash
          state
          (format "bilingual: word translation failed: ~a"
                  (job-error-message result)))
         ps0
         '())]
       [(not (and (list? result) (= 2 (length result))))
        (values state ps0 '())]
       [else
        (define result-generation (list-ref result 0))
        (define entries (list-ref result 1))
        (cond
          [(not (equal? result-generation
                        (lexicon-generation lex)))
           (values state ps0 '())]
          [else
           (define-values (lex* added conflicts)
             (lexicon-merge lex0 entries
                            (translator-forward default-translator)
                            (translator-inverse default-translator)))
           (define ps1 (state-set-lexicon ps lex*))
           (cond
             [(null? added)
              (values
               (state-with-flash
                state
                (if (null? conflicts)
                    "bilingual: no word translations added"
                    (format "bilingual: ~a word translation conflict(s)"
                            (length conflicts))))
               ps1
               '())]
             [else
              (define tr (lexicon->translator lex*))
              (define ps2
                (state-set-translator ps1 default-translator-id tr))
              (define-values (state* ps3)
                (update-pairs-after-lexicon! ed state ps2 added tr))
              (values
               (state-with-flash
                state*
                (format "bilingual: added ~a words~a"
                        (length added)
                        (if (null? conflicts)
                            ""
                            (format " (~a conflicts)"
                                    (length conflicts)))))
               ps3
               '())])])])]))

(define (handle-bilingual-edit-job ed state ps ev)
  (define result (job-result-event-result ev))
  (define tag (job-result-event-tag ev))
  (define source-doc-id (and (list? tag) (not (null? tag)) (car tag)))
  (define p (and source-doc-id (pair-for-source ps source-doc-id)))
  (cond
    [(not p) (values state ps '())]
    [(not (equal? (pair-pending-job-id p) (job-result-event-id ev)))
     (values state ps '())]
    [(job-error? result)
     (values (state-with-flash
              state
              (format "bilingual: translation failed: ~a"
                      (job-error-message result)))
             (clear-pending ps p)
             '())]
    [(not (and (list? result) (= 11 (length result))))
     (values state (clear-pending ps p) '())]
    [else
     (define r-source-doc-id (list-ref result 0))
     (define r-version (list-ref result 1))
     (define r-translator-id (list-ref result 2))
     (define r-translator-version (list-ref result 3))
     (define os (list-ref result 4))
     (define oe (list-ref result 5))
     (define ns (list-ref result 6))
     (define ne (list-ref result 7))
     (define r-source-lines (list-ref result 8))
     (define translated-lines (list-ref result 9))
     (define translated-faces (list-ref result 10))
     (define current-version (editor-doc-version ed source-doc-id))
     (define old-source-lines (pair-source-lines p))
     (define old-mirror-lines (pair-mirror-lines p))
     (define old-mirror-faces (pair-mirror-faces p))
     (cond
       [(or (not (equal? r-source-doc-id source-doc-id))
            (not (equal? r-version current-version))
            (not (equal? r-translator-id (pair-translator-id p)))
            (not (equal? r-translator-version (pair-translator-version p)))
            (not (= (length old-source-lines) (length old-mirror-lines)))
            (not (= (length old-mirror-faces) (length old-mirror-lines)))
            (not (<= 0 os oe (length old-source-lines)))
            (not (<= 0 ns ne (length r-source-lines)))
            (not (= (length translated-lines) (length translated-faces)))
            (not (= (length translated-lines) (- ne ns))))
        ;; 旧结果 / 形状不一致：丢弃；下一次 sync 会重新选 full 或 edit。
        (values state (clear-pending ps p) '())]
       [else
        (define new-mirror-lines
          (append (take old-mirror-lines os)
                  translated-lines
                  (drop old-mirror-lines oe)))
        (define new-mirror-faces
          (append (take old-mirror-faces os)
                  translated-faces
                  (drop old-mirror-faces oe)))
        (write-mirror! ed (pair-mirror-view-id p)
                       new-mirror-lines new-mirror-faces)
        (define p*
          (struct-copy pair p
                       [translator-version r-translator-version]
                       [source-version r-version]
                       [mirror-version (editor-doc-version
                                        ed (pair-mirror-doc-id p))]
                       [pending-version #f]
                       [pending-job-id #f]
                       [timer-id #f]
                       [source-lines r-source-lines]
                       [mirror-lines new-mirror-lines]
                       [mirror-faces new-mirror-faces]))
        (values state (state-set-pair ps p*) '())])]))

(define (handle-bilingual-retranslate-job ed state ps ev)
  (define result (job-result-event-result ev))
  (define tag (job-result-event-tag ev))
  (define source-doc-id (and (list? tag) (not (null? tag)) (car tag)))
  (define p (and source-doc-id (pair-for-source ps source-doc-id)))
  (cond
    [(not p) (values state ps '())]
    [(not (equal? (pair-pending-job-id p) (job-result-event-id ev)))
     (values state ps '())]
    [(job-error? result)
     (values (state-with-flash
              state
              (format "bilingual: line retranslate failed: ~a"
                      (job-error-message result)))
             (clear-pending ps p)
             '())]
    [(not (and (list? result) (= 8 (length result))))
     (values state (clear-pending ps p) '())]
    [else
     (define r-did (list-ref result 0))
     (define r-version (list-ref result 1))
     (define r-tr-id (list-ref result 2))
     (define r-tr-version (list-ref result 3))
     (define r-source-lines (list-ref result 4))
     (define dirty-lines (list-ref result 5))
     (define translated-lines (list-ref result 6))
     (define translated-faces (list-ref result 7))
     (define current-version (editor-doc-version ed source-doc-id))
     (cond
       [(or (not (equal? r-did source-doc-id))
            (not (equal? r-version current-version))
            (not (equal? r-tr-id (pair-translator-id p))))
        (values state (clear-pending ps p) '())]
       [else
        (define p*
          (apply-retranslated-lines!
           ed p r-source-lines dirty-lines
           translated-lines translated-faces
           r-version r-tr-version))
        (values state
                (if p*
                    (state-set-pair ps p*)
                    (clear-pending ps p))
                '())])]))

(define (handle-bilingual-job ed state ps ev)
  (define kind (job-result-event-kind ev))
  (cond
    [(eq? kind word-translation-kind)
     (if (bilingual-state? ps)
         (handle-bilingual-word-job ed state ps ev)
         (values state ps '()))]
    [(eq? kind edit-translation-kind)
     (if (bilingual-state? ps)
         (handle-bilingual-edit-job ed state ps ev)
         (values state ps '()))]
    [(eq? kind retranslate-kind)
     (if (bilingual-state? ps)
         (handle-bilingual-retranslate-job ed state ps ev)
         (values state ps '()))]
    [(not (eq? kind translation-kind))
     (values state ps '())]
    [(not (bilingual-state? ps))
     (values state ps '())]
    [else
     (define result (job-result-event-result ev))
     (define tag (job-result-event-tag ev))
     (define source-doc-id
       (and (list? tag) (not (null? tag)) (car tag)))
     (define p (and source-doc-id (pair-for-source ps source-doc-id)))
     (cond
       [(not p) (values state ps '())]
       [(not (equal? (pair-pending-job-id p) (job-result-event-id ev)))
        (values state ps '())]
       [(job-error? result)
        (values (state-with-flash
                 state
                 (format "bilingual: translation failed: ~a"
                         (job-error-message result)))
                (clear-pending ps p)
                '())]
       [(not (and (list? result) (= 7 (length result))))
        (values state (clear-pending ps p) '())]
       [else
        (define r-source-doc-id (list-ref result 0))
        (define r-version (list-ref result 1))
        (define r-translator-id (list-ref result 2))
        (define r-translator-version (list-ref result 3))
        (define r-source-lines (list-ref result 4))
        (define r-mirror-lines (list-ref result 5))
        (define r-mirror-faces (list-ref result 6))
        (define current-version (editor-doc-version ed source-doc-id))
        (cond
          [(or (not (equal? r-source-doc-id source-doc-id))
               (not (equal? r-version current-version))
               (not (equal? r-translator-id (pair-translator-id p)))
               (not (equal? r-translator-version
                            (pair-translator-version p))))
           ;; 旧结果：丢掉，下一次 sync 会按当前版本 / translator 重新提交。
           (values state (clear-pending ps p) '())]
          [else
           (write-mirror! ed (pair-mirror-view-id p)
                          r-mirror-lines r-mirror-faces)
           (define p*
             (struct-copy pair p
                          [source-version r-version]
                          [mirror-version (editor-doc-version
                                           ed (pair-mirror-doc-id p))]
                          [pending-version #f]
                          [pending-job-id #f]
                          [timer-id #f]
                          [source-lines r-source-lines]
                          [mirror-lines r-mirror-lines]
                          [mirror-faces r-mirror-faces]))
           (values state (state-set-pair ps p*) '())])])]))

(define (sync-bilingual! ed state ps)
  (cond
    [(not (bilingual-state? ps)) (values state ps)]
    [(state-async? state)
     (define-values (state1 ps1)
       (for/fold ([state state] [ps ps])
                 ([p (in-list (hash-values (bilingual-state-pairs ps)))])
         (ensure-pair-async! ed state ps p)))
     (define ps2
       (for/fold ([ps ps1])
                 ([p (in-list (hash-values (bilingual-state-pairs ps1)))])
         (sync-pair-viewport! ed state1 p ps)))
     (values state1 ps2)]
    [else
     (define ps1
       (for/fold ([ps ps])
                 ([p (in-list (hash-values (bilingual-state-pairs ps)))])
         (project-pair-sync ed ps p)))
     (define ps2
       (for/fold ([ps ps1])
                 ([p (in-list (hash-values (bilingual-state-pairs ps1)))])
         (sync-pair-viewport! ed state p ps)))
     (values state ps2)]))

;;; ════════════════ 命令 ════════════════

(define (full-translate-command ed state ps)
  (define vid (editor-focus-view-id state))
  (define did (and vid (editor-view-doc-id ed vid)))
  (define p
    (and did
         (case (editor-doc-kind ed did)
           [(user) (pair-for-source ps did)]
           [(derived) (pair-for-mirror ps did)]
           [else #f])))
  (cond
    [(not p)
     (flash-message state "bilingual: no pair for this buffer")]
    [else
     (when (pair-timer-id p)
       (editor-cancel-timer! ed (pair-timer-id p)))
     (define p1
       (struct-copy pair p
                    [force-full? #t]
                    [timer-id #f]
                    [pending-version #f]
                    [pending-job-id #f]))
     (define ps1 (state-set-pair ps p1))
     (cond
       [(state-async? state)
        (define-values (state* ps2)
          (submit-projection-job! ed state ps1 p1 #:force-full? #t))
        (values (state-with-flash state* "bilingual: full translation started")
                ps2
                '())]
       [else
        (values (state-with-flash state "bilingual: full translation done")
                (full-project-pair-sync ed ps1 p1)
                '())])]))

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

(define (make-bilingual-plugin #:word-translator [word-translator #f])
  (define (word-service payload)
    (define generation (list-ref payload 1))
    (define entries
      (if word-translator
          (word-translator payload)
          '()))
    (list generation (if (list? entries) entries '())))
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
   #:services (list (service 'bilingual-translate bilingual-translate-service)
                    (service 'bilingual-translate-edit bilingual-translate-edit-service)
                    (service 'bilingual-retranslate-lines bilingual-retranslate-lines-service)
                    (service 'bilingual-word-translate word-service))
   #:handle-job handle-bilingual-job
   #:handle-timer handle-bilingual-timer
   #:commands
   (keys
    [(key 'l 'alt) toggle-bilingual-command]
    [(key 'x 'ctrl) (key 't) full-translate-command])))

(define bilingual-plugin (make-bilingual-plugin))

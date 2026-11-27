#lang racket

;;; edit-tui/plugins/racket-color/plugin.rkt —— Racket 语法着色
;;;
;;; 两条路径：
;;;   · sync（headless / 测试）：changes 用 color-edit* 增量写 dirty face lines；
;;;     sync 在版本变化时整篇 color-open，并给新 view 写完整 face track。
;;;   · async（TUI）：主线程只提交「版本 + 焦点」请求；face worker 内合成
;;;     syntax / word / bracket，一次 swap 写完整 face track，再发 paint signal。
;;;
;;; 非 Racket 文档完全不碰 face track，避免清掉 filetree / status 自己的 face。

(require racket/string
         "../../editor/api.rkt"
         "../../lang/racket/api.rkt"
         "../../core/face/api.rkt")

(provide racket-color-plugin
         (struct-out color-entry))

(struct color-entry
  (version
   color-state
   face-track
   bracket-pairs-version
   bracket-pairs)
  #:transparent)

;; async 路径只需要记住「已提交到哪个版本 / 光标签名」，不保存 color-state。
;; 真正的 color-state / face-track 在 face worker 内按 buffer 缓存。
(struct color-request (version focus) #:transparent)
(struct color-worker-entry
  (version color-state bracket-pairs-version bracket-pairs)
  #:transparent)

(define empty-color-cache (hash))

;; face worker 只在单线程执行；同步兜底也只会由同一时刻的主线程进入。
;; key = buffer（eq?）；ephemeron 避免已关闭 buffer 的缓存阻止回收。
(define color-worker-cache (make-ephemeron-hasheq))

;; 优先看 resource mode；没有 resource 的临时测试文档才退回文本判断。
(define (racket-doc? state did text)
  (or (eq? (state-doc-mode state did) 'racket)
      (and (not (state-resource-for-doc state did))
           (racket-text? text))))

;; 焦点在 doc 内时返回 (cons line col)，否则 #f。
(define (doc-focus-info ed state did)
  (define vid (editor-focus-view-id state))
  (define fdid (and vid (editor-view-doc-id ed vid)))
  (and (equal? fdid did)
       (let ([line (editor-view-point-line ed vid)]
             [col (editor-view-point-column ed vid)])
         (and line col (cons line col)))))

;;; ════════════════ role -> face ════════════════

(define (bracket-role? role)
  (and role
       (string-prefix? (symbol->string role) "bracket-depth-")))

;; 括号字符 / 配对标记：前景用同层提亮色，背景仍用该层深度背景。
(define (bracket-glyph-role? role)
  (and (bracket-role? role)
       (let ([s (symbol->string role)])
         (or (string-suffix? s "-bracket")
             (string-suffix? s "-match")))))

(define (role->face-layer role)
  (cond
    [(bracket-glyph-role? role)
     (face role (bracket-glyph-bg-role role) '())]
    [(bracket-role? role) (face #f role '())]
    [else (face role #f '())]))

(define (role-at roles i)
  (and roles
       (< i (vector-length roles))
       (vector-ref roles i)))

(define (line->faces syntax word bracket
                     [suppress-start #f] [suppress-end #f]
                     [match-roles #f] [line-no #f])
  (define n (vector-length syntax))
  (for/vector ([i (in-range n)])
    (define f #f)
    (define br0 (role-at bracket i))
    ;; 匹配括号用同层更亮的 match role 覆盖普通括号字符 role。
    (define br (or (and match-roles line-no
                        (hash-ref match-roles (cons line-no i) #f))
                   br0))
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
;; match-roles = hash (line . col) -> bracket-depth-N-match | #f
(define (color-state->face-track cs suppress [match-roles #f])
  (define sl (and suppress (car suppress)))
  (define sr (and suppress (cdr suppress)))
  (for/list ([syntax (in-vector (color-state-syntax-roles cs))]
             [word (in-vector (color-state-word-roles cs))]
             [bracket (in-vector (color-state-bracket-roles cs))]
             [ln (in-naturals)])
    (if (and sl (= ln sl))
        (line->faces syntax word bracket (car sr) (cdr sr)
                     match-roles ln)
        (line->faces syntax word bracket #f #f match-roles ln))))

(define (color-state->dirty-face-lines cs dirty-lines suppress
                                       [match-roles #f])
  (define syntax (color-state-syntax-roles cs))
  (define word (color-state-word-roles cs))
  (define bracket (color-state-bracket-roles cs))
  (define sl (and suppress (car suppress)))
  (define sr (and suppress (cdr suppress)))
  (for/list ([ln (in-list dirty-lines)])
    (cons ln (if (and sl (= ln sl))
                 (line->faces (vector-ref syntax ln) (vector-ref word ln)
                              (vector-ref bracket ln) (car sr) (cdr sr)
                              match-roles ln)
                 (line->faces (vector-ref syntax ln) (vector-ref word ln)
                              (vector-ref bracket ln) #f #f
                              match-roles ln)))))

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

;; focus = (cons line col) | #f。纯函数：主线程和 face worker 共用。
(define (suppress-at-focus cs focus)
  (and focus
       (let ([range (active-word-range cs (car focus) (cdr focus))])
         (and range (cons (car focus) range)))))

;; 焦点 view 是否属于 doc；属于才抑制该行的 word-color。
(define (focus-suppress ed state did cs)
  (suppress-at-focus cs (doc-focus-info ed state did)))

;;; ════════════════ 光标括号配对 ════════════════

(define (bracket-role-at cs line col)
  (define role-vectors (color-state-bracket-roles cs))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (vector-length role-vectors)))
     #f]
    [else
     (define roles (vector-ref role-vectors line))
     (and (exact-nonnegative-integer? col)
          (< col (vector-length roles))
          (vector-ref roles col))]))

;; focus = (cons line col) | #f。纯函数：主线程和 face worker 共用。
(define (bracket-position-at-focus cs focus)
  (and focus
       (let ([line (car focus)] [col (cdr focus)])
         (cond
           [(bracket-char-role? (bracket-role-at cs line col)) (cons line col)]
           [(and (> col 0)
                 (bracket-char-role? (bracket-role-at cs line (sub1 col))))
            (cons line (sub1 col))]
           [else #f]))))

;; 光标在括号上（或紧跟括号之后）时返回该括号位置 (line . col)。
;; 用 bracket role 判断，字符串 / 注释里的括号不会被误认。
(define (focus-bracket-position ed state did cs)
  (bracket-position-at-focus cs (doc-focus-info ed state did)))

;; 按 (doc-id, version) 缓存整篇配对表；只有光标落到括号上才需要计算。
(define (ensure-bracket-pairs entry text version)
  (cond
    [(equal? (color-entry-bracket-pairs-version entry) version)
     entry]
    [else
     (color-entry version
                  (color-entry-color-state entry)
                  (color-entry-face-track entry)
                  version
                  (bracket-pair-map text))]))

;; 配对两端 -> role hash；找不到匹配就返回 #f（未匹配括号保持普通括号色）。
(define (match-positions->roles cs positions)
  (and positions
       (for/fold ([h (hash)]) ([pos (in-list positions)])
         (define role (bracket-role-at cs (car pos) (cdr pos)))
         (define match-role (and (bracket-char-role? role)
                                 (bracket-match-role-of role)))
         (if match-role
             (hash-set h pos match-role)
             h))))

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

(define (write-full-track! ed did version vids entry suppress match-roles)
  (define key (list did version 'racket-color suppress match-roles))
  (define track
    (if (or suppress match-roles)
        (color-state->face-track (color-entry-color-state entry)
                                 suppress match-roles)
        (color-entry-face-track entry)))
  (for ([vid (in-list vids)])
    (editor-set-view-face-track! ed vid track
                                 #:base-version version
                                 #:key key)))

(define (write-dirty-lines! ed did version vids cs dirty suppress
                            [match-roles #f])
  (define key (list did version 'racket-color suppress match-roles))
  (define lines (color-state->dirty-face-lines cs dirty suppress match-roles))
  (for ([vid (in-list vids)])
    (editor-set-view-face-lines! ed vid lines
                                 #:base-version version
                                 #:key key)))

;;; ════════════════ 后台 face worker ════════════════

;; 在 worker 内维护 color-state 缓存。同一 buffer 的旧任务会被 face runtime
;; 合并掉，所以这里拿到的 text/version 总是该 buffer 最新一次提交的内容。
(define (worker-color-state old text version base-version changes kind)
  (cond
    [(and old (equal? (color-worker-entry-version old) version))
     (values (color-worker-entry-color-state old) old)]
    [(and (eq? kind 'edit)
          old
          (equal? (color-worker-entry-version old) base-version))
     (define-values (cs _dirty)
       (color-edit* (color-worker-entry-color-state old)
                    text
                    (changes->line-edits changes)))
     (values cs old)]
    [else
     (values (color-open text) #f)]))

;; 语法 / 同词 / 括号在同一个函数里按 line->faces 固定顺序合成，一次写出
;; 整条 face track。写完由 face runtime 发 paint signal。
(define (color-worker-job! target text version base-version changes focus kind)
  (define buffer (face-target-buffer target))
  (define old (hash-ref color-worker-cache buffer #f))
  (define-values (cs old-entry)
    (worker-color-state old text version base-version changes kind))
  (define bracket-pos (bracket-position-at-focus cs focus))
  (define bracket-pairs
    (cond
      [(not bracket-pos) #f]
      [(and old-entry
            (equal? (color-worker-entry-bracket-pairs-version old-entry)
                    version))
       (color-worker-entry-bracket-pairs old-entry)]
      [else (bracket-pair-map text)]))
  (define match
    (and bracket-pos
         (let ([other (hash-ref bracket-pairs bracket-pos #f)])
           (and other (list bracket-pos other)))))
  (define match-roles (match-positions->roles cs match))
  (define suppress (suppress-at-focus cs focus))
  (define face-track (color-state->face-track cs suppress match-roles))
  (face-target-set-face-lines! target face-track)
  (hash-set! color-worker-cache buffer
             (color-worker-entry version cs
                                (and bracket-pos version)
                                bracket-pairs)))

;;; ════════════════ changes hook ════════════════

(define (changes-color ctx ps)
  (define ed (change-context-editor ctx))
  (define state (change-context-state ctx))
  (define did (change-context-doc-id ctx))
  (define base-version (change-context-base-version ctx))
  (define version (change-context-version ctx))
  (define changes (change-context-changes ctx))
  (define text (editor-doc-text ed did))
  (cond
    [(or (not text)
         (not (eq? (editor-doc-kind ed did) 'user))
         (not (racket-doc? state did text)))
     (values ctx ps '() #t)]
    [(state-async? state)
     (define target (editor-doc-face-target ed did))
     (cond
       [(not target)
        ;; 没有可见 view 时不做 face 工作；下一次 sync 会重新判断。
        (values ctx (hash-remove ps did) '() #t)]
       [else
        (define focus (doc-focus-info ed state did))
        (define buffer (face-target-buffer target))
        (face-submit! buffer
                      (λ ()
                        (color-worker-job! target text version base-version
                                           changes focus 'edit)))
        (values ctx (hash-set ps did (color-request version focus)) '() #t)])]
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
     (define entry (color-entry version cs (color-state->face-track cs #f) #f #f))
     (define suppress (focus-suppress ed state did cs))
     (define vids (editor-view-ids-for-doc ed did))
     (cond
       [(eq? dirty 'all)
        (write-full-track! ed did version vids entry suppress #f)]
       [else
        (when (pair? dirty)
          (write-dirty-lines! ed did version vids cs dirty suppress))])
     (values ctx (hash-set ps did entry) '() #t)]))

;;; ════════════════ sync ════════════════

(define (sync-colors ed state ps)
  (cond
    [(state-async? state)
     ;; async：主线程只判断「是否需要提交新请求」。color-state / face track
     ;; 在 worker 内；这里不碰 face。
     (define ps*
       (for/fold ([ps ps]) ([did (in-list (editor-user-doc-ids ed))])
         (define text (editor-doc-text ed did))
         (define version (editor-doc-version ed did))
         (define target (and text version (editor-doc-face-target ed did)))
         (cond
           [(or (not text)
                (not version)
                (not target)
                (not (racket-doc? state did text)))
            (hash-remove ps did)]
           [else
            (define focus (doc-focus-info ed state did))
            (define req (hash-ref ps did #f))
            (cond
              [(and (color-request? req)
                    (equal? (color-request-version req) version)
                    (equal? (color-request-focus req) focus))
               ps]
              [else
               (define buffer (face-target-buffer target))
               (face-submit! buffer
                             (λ ()
                               (color-worker-job! target text version #f
                                                  '() focus 'sync)))
               (hash-set ps did (color-request version focus))])])))
     (values state ps*)]
    [else
     (define old-cache (if (hash? ps) ps empty-color-cache))
     (define (sync-doc cache did)
       (define text (editor-doc-text ed did))
       (define version (editor-doc-version ed did))
       (define vids (or (editor-view-ids-for-doc ed did) '()))
       (cond
         [(or (not text) (not version) (null? vids)) cache]
         [(not (racket-doc? state did text)) cache]
         [else
          (define cached (hash-ref old-cache did #f))
          (define entry0
            (if (and cached (equal? (color-entry-version cached) version))
                cached
                (let ([cs (color-open text)])
                  (color-entry version cs (color-state->face-track cs #f) #f #f))))
          (define cs (color-entry-color-state entry0))
          ;; 只有光标真的落在括号上，才需要整篇配对表。
          (define bracket-pos (focus-bracket-position ed state did cs))
          (define entry (if bracket-pos
                            (ensure-bracket-pairs entry0 text version)
                            entry0))
          (define match
            (and bracket-pos
                 (let ([other (hash-ref (color-entry-bracket-pairs entry)
                                        bracket-pos #f)])
                   (and other (list bracket-pos other)))))
          (define match-roles (match-positions->roles cs match))
          (define suppress (focus-suppress ed state did cs))
          (write-full-track! ed did version vids entry suppress match-roles)
          (hash-set cache did entry)]))
     (define new-cache
       (for/fold ([cache (hash)]) ([did (in-list (editor-user-doc-ids ed))])
         (sync-doc cache did)))
     (values state new-cache)]))

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

#lang racket

;;; edit-tui/plugins/filetree/plugin.rkt —— 文件树
;;;
;;; 当前能力：
;;;   · root / 目录 / 文件 行投影
;;;   · 用两空格缩进 + face（root / dir / open / file）区分层次和类型
;;;   · 目录展开 / 折叠
;;;   · 隐藏 dotfile 的显示 / 隐藏
;;;   · C-f n / C-f C-f n / C-f d / C-f r -> create/delete/rename action（IO 在 host）
;;;   · C-f s 一次性查找文件；匹配路径在原文件树里展开并定位，不覆盖树
;;;   · C-left / C-right 在本次查找的匹配项间移动
;;;   · C-f l / C-r 重扫普通树（不会重跑上次查找）
;;;   · Enter 打开文件 -> open-file-action
;;;
;;; 插件状态是纯值：root / view / expanded / show-hidden? / rows / pending-cursor
;;; + 查找会话（find-query / find-stale? / find-pending / find-matches / find-truncated?）。
;;; 普通树扫描和递归查找都在 sync 阶段做；生产路径走异步 job。
;;; 回调用当前 ps 读写自己的状态；跨插件 / host 请求用 action。

(require racket/file
         (only-in racket/list append* drop-right)
         racket/path
         racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt")

(provide make-filetree-plugin
         (struct-out filetree-state)
         filetree-find-submit!
         filetree-clear-find!)

(struct filetree-state
  (root
   view
   expanded      ; hash path -> #t
   show-hidden?  ; bool
   rows          ; (listof row)
   stale?        ; #t = 需要重扫普通树
   pending       ; #f | 正在后台扫描的 projection tag
   pending-cursor ; #f | path：sync 后把光标放到该 path 的行
   find-query    ; #f | string：最近一次查找 query（只用于 C-f s 预填）
   find-stale?   ; #t = 需要重跑查找
   find-pending  ; #f | 正在后台查找的 tag
   find-matches  ; (listof path)：最近一次查找的匹配路径
   find-index    ; 当前匹配项索引；C-left / C-right 移动
   find-truncated?) ; bool：结果是否被上限截断
  #:transparent)

;; row = (list path kind text depth)
(define (row-path row) (car row))
(define (row-kind row) (cadr row))
(define (row-text row) (caddr row))
(define (row-depth row) (cadddr row))

(define find-limit 200)

(define (hidden-name? s)
  (and (positive? (string-length s))
       (char=? (string-ref s 0) #\.)))

(define (default-hidden-entry? path)
  (hidden-name? (path->string (file-name-from-path path))))

(define (list-entries dir show-hidden? hidden-entry?)
  (with-handlers ([exn:fail? (λ (_) '())])
    (sort (filter (λ (p)
                    (or show-hidden?
                        (not (hidden-entry? p))))
                  (directory-list dir))
          string<?
          #:key path->string)))

(define (scan-tree root expanded show-hidden? hidden-entry?)
  (define (children dir depth)
    (append*
     (for/list ([p (in-list (list-entries dir show-hidden? hidden-entry?))])
       (define full (build-path dir p))
       (define name (path->string p))
       (define label (string-append (make-string (* 2 depth) #\space) name))
       (cond
         [(directory-exists? full)
          (define self (list full 'dir label depth))
          (if (hash-ref expanded full #f)
              (cons self (children full (add1 depth)))
              (list self))]
         [else
          (list (list full 'file label depth))]))))
  (define root-row (list root 'root (path->string root) 0))
  (if (hash-ref expanded root #f)
      (cons root-row (children root 1))
      (list root-row)))

;;; ════════════════ 查找 ════════════════

;; 在 root 下递归找“相对路径包含 query”的条目。
;; 目录本身也参与匹配；不跟随符号链接目录，避免环；最多返回 find-limit 条。
(define (search-tree root query show-hidden? hidden-entry?)
  (define needle (string-downcase query))
  (define matches '())
  (define count 0)
  (define truncated? #f)
  (define (walk dir)
    (for ([p (in-list (list-entries dir show-hidden? hidden-entry?))])
      (unless truncated?
        (define full (build-path dir p))
        (define symlink? (link-exists? full))
        (define dir? (and (not symlink?) (directory-exists? full)))
        (define file? (and (not dir?) (file-exists? full)))
        (when (or dir? file?)
          (define rel (find-relative-path root full))
          (define label (path->string rel))
          (when (string-contains? (string-downcase label) needle)
            (if (>= count find-limit)
                (set! truncated? #t)
                (begin
                  (set! matches (cons full matches))
                  (set! count (add1 count)))))
          (when (and dir? (not truncated?))
            (walk full))))))
  (walk root)
  (values (reverse matches) truncated?))

(define (search-tag st)
  (list (filetree-state-root st)
        (filetree-state-find-query st)
        (filetree-state-show-hidden? st)))

(define (make-filetree-search-service hidden-entry?)
  (service 'filetree-search
           (λ (payload)
             (define-values (root query show-hidden?) (apply values payload))
             (define-values (matches truncated?)
               (search-tree root query show-hidden? hidden-entry?))
             (list matches truncated?))))

(define (row-face row opened)
  (case (row-kind row)
    [(root) 'filetree-root]
    [(dir) 'filetree-dir]
    [(file) (if (hash-has-key? opened (resource-normalize-path (row-path row)))
                'filetree-open
                'filetree-file)]
    [else 'filetree-file]))

(define (find-line rows path)
  (for/first ([row (in-list rows)] [i (in-naturals)]
              #:when (equal? (row-path row) path))
    i))

(define (projection-tag st)
  (list (filetree-state-root st)
        (filetree-state-expanded st)
        (filetree-state-show-hidden? st)))

(define (make-filetree-scan-service hidden-entry?)
  (service 'filetree-scan
           (λ (payload)
             (define-values (root expanded show-hidden?) (apply values payload))
             (scan-tree root expanded show-hidden? hidden-entry?))))

;;; ════════════════ 查找状态切换 / 定位 ════════════════

;; root 下 path 的祖先目录（含 root，不含 path 本身）；root 外 -> #f。
(define (path-ancestors root path)
  (define rel (with-handlers ([exn:fail? (λ (_) #f)])
                (find-relative-path root path)))
  (define rel-str (and rel (path->string rel)))
  (cond
    [(or (not rel)
         (absolute-path? rel)
         (regexp-match? #rx"^\\.\\.[/\\\\]" rel-str))
     #f]
    [else
     (define parts (explode-path rel))
     (define dirs (drop-right parts 1))
     (let loop ([parts dirs] [prefix root] [acc (list root)])
       (cond
         [(null? parts) (reverse acc)]
         [else
          (define next (build-path prefix (car parts)))
          (loop (cdr parts) next (cons next acc))]))]))

;; path 所在链上的目录都展开，让 path 在普通树里可见。
(define (expand-parents expanded root path)
  (define dirs (path-ancestors root path))
  (cond
    [(not dirs) expanded]
    [else
     (for/fold ([h expanded]) ([d (in-list dirs)])
       (hash-set h d #t))]))

;; 提交查找只记录 query；文件树保持原样，等结果回来后再展开 / 定位。
(define (filetree-find-submit! st query)
  (define q (string-trim query))
  (cond
    [(string=? q "")
     (filetree-clear-find! st)]
    [else
     (struct-copy filetree-state st
                  [find-query q]
                  [find-stale? #t]
                  [find-pending #f]
                  [find-matches '()]
                  [find-index 0]
                  [find-truncated? #f])]))

;; 清掉查找会话；不覆盖 rows / expanded，也不移动光标。
(define (filetree-clear-find! st)
  (struct-copy filetree-state st
               [find-query #f]
               [find-stale? #f]
               [find-pending #f]
               [find-matches '()]
               [find-index 0]
               [find-truncated? #f]))

;;; ════════════════ job result ════════════════

(define (search-message state query matches truncated?)
  (cond
    [(null? matches) (state-with-flash state (format "find: no match: ~a" query))]
    [truncated? (state-with-flash state (format "find: ~a+ matches" find-limit))]
    [else state]))

;; 把查找结果合回普通树：
;;   · 不替换 rows；
;;   · 展开第一条匹配路径的祖先目录；
;;   · 设置 pending-cursor，让下一次 tree scan 写完后把光标放到该行。
(define (apply-search-result state ps matches truncated?)
  (define first-path (and (pair? matches) (car matches)))
  (define base
    (struct-copy filetree-state ps
                 [find-matches matches]
                 [find-index 0]
                 [find-pending #f]
                 [find-stale? #f]
                 [find-truncated? truncated?]))
  (cond
    [(not first-path)
     (values (search-message state (filetree-state-find-query ps)
                             matches truncated?)
             base
             '())]
    [else
     (define expanded
       (expand-parents (filetree-state-expanded ps)
                       (filetree-state-root ps)
                       first-path))
     (values (search-message state (filetree-state-find-query ps)
                             matches truncated?)
             (struct-copy filetree-state base
                          [expanded expanded]
                          [stale? #t]
                          [pending-cursor first-path])
             '())]))

(define (handle-scan-result state ps ev)
  (define tag (job-result-event-tag ev))
  (define result (job-result-event-result ev))
  (define current-tag (projection-tag ps))
  (cond
    [(job-error? result)
     (values (state-with-flash state "filetree scan failed")
             (struct-copy filetree-state ps [pending #f] [stale? #f])
             '())]
    [(equal? tag current-tag)
     (values state
             (struct-copy filetree-state ps
                          [rows result]
                          [pending #f]
                          [stale? #f])
             '())]
    [else
     ;; 扫描期间投影又变了：丢掉旧结果，下一帧重新提交。
     (values state
             (struct-copy filetree-state ps [pending #f])
             '())]))

(define (handle-search-result state ps ev)
  (define tag (job-result-event-tag ev))
  (define result (job-result-event-result ev))
  (define current-tag (search-tag ps))
  (cond
    [(not (equal? tag current-tag))
     ;; 已有更新的查找在跑 / 已退出查找 / 树状态变了：丢弃旧结果。
     (define ps*
       (if (equal? tag (filetree-state-find-pending ps))
           (struct-copy filetree-state ps [find-pending #f] [find-stale? #f])
           ps))
     (values state ps* '())]
    [(job-error? result)
     (values (state-with-flash state "filetree find failed")
             (struct-copy filetree-state ps [find-pending #f] [find-stale? #f])
             '())]
    [else
     (define-values (matches truncated?) (apply values result))
     (apply-search-result state ps matches truncated?)]))

(define (handle-filetree-job ed state ps ev)
  (cond
    [(not (filetree-state? ps)) (values state ps '())]
    [else
     (case (job-result-event-kind ev)
       [(filetree-scan) (handle-scan-result state ps ev)]
       [(filetree-search) (handle-search-result state ps ev)]
       [else (values state ps '())])]))

;;; ════════════════ 投影 ════════════════

(define (write-filetree! ed state st rows)
  (define vid (filetree-state-view st))
  (define opened (state-opened-paths state))
  (editor-set-view-content! ed vid
                           (map row-text rows)
                           (map (λ (row) (row-face row opened)) rows))
  (define pending (filetree-state-pending-cursor st))
  (cond
    [(not pending) (struct-copy filetree-state st [rows rows])]
    [else
     (define line (find-line rows pending))
     (cond
       [line
        (editor-set-view-cursor! ed vid line #:column 0)
        (struct-copy filetree-state st [rows rows] [pending-cursor #f])]
       [else (struct-copy filetree-state st [rows rows])])]))

;;; ════════════════ sync ════════════════

;; 查找只负责算 matches / 安排展开；普通树投影统一由 sync-tree 做。
(define (sync-find ed state ps hidden-entry?)
  (cond
    [(not (filetree-state-find-query ps)) (values state ps)]
    [(and (not (state-async? state))
          (filetree-state-find-stale? ps))
     (define-values (matches truncated?)
       (search-tree (filetree-state-root ps)
                    (filetree-state-find-query ps)
                    (filetree-state-show-hidden? ps)
                    hidden-entry?))
     (define-values (state* ps* _actions)
       (apply-search-result state ps matches truncated?))
     (values state* ps*)]
    [(not (state-async? state)) (values state ps)]
    [else
     (define find?
       (and (filetree-state-find-stale? ps)
            (not (filetree-state-find-pending ps))))
     (define tag (search-tag ps))
     (define base-state
       (if find?
           (let-values ([(state* _job)
                         (state-submit-job state 'filetree-search tag tag)])
             state*)
           state))
     (define ps1
       (if find?
           (struct-copy filetree-state ps [find-pending tag])
           ps))
     (values base-state ps1)]))

(define (sync-tree ed state ps hidden-entry?)
  (define root (filetree-state-root ps))
  (define expanded (filetree-state-expanded ps))
  (define show-hidden? (filetree-state-show-hidden? ps))
  (define tag (projection-tag ps))
  (cond
    [(not (state-async? state))
     (define rows
       (if (filetree-state-stale? ps)
           (scan-tree root expanded show-hidden? hidden-entry?)
           (filetree-state-rows ps)))
     (define ps* (write-filetree! ed state ps rows))
     (values state
             (struct-copy filetree-state ps* [stale? #f] [pending #f]))]
    [else
     (define scan?
       (and (filetree-state-stale? ps)
            (not (filetree-state-pending ps))))
     (define base-state
       (if scan?
           (let-values ([(state* _job)
                         (state-submit-job state 'filetree-scan tag tag)])
             state*)
           state))
     (define ps1
       (if scan?
           (struct-copy filetree-state ps [pending tag])
           ps))
     (values base-state
             (write-filetree! ed base-state ps1
                              (filetree-state-rows ps1)))]))

(define (make-sync-filetree hidden-entry?)
  (λ (ed state ps)
    (cond
      [(not (filetree-state? ps)) (values state ps)]
      [else
       (define-values (state1 ps1) (sync-find ed state ps hidden-entry?))
       (sync-tree ed state1 ps1 hidden-entry?)])))

;;; ════════════════ 命令 ════════════════

(define (filetree-focused? state vid)
  (eq? (editor-focus-view-id state) vid))

(define (current-row ed state ps vid)
  (define rows (and (filetree-state? ps) (filetree-state-rows ps)))
  (define line (editor-view-point-line ed vid))
  (and rows line (< line (length rows)) (list-ref rows line)))

(define (refresh-state st path)
  (struct-copy filetree-state st
               [stale? #t]
               [pending-cursor path]))

(define (open-row-action row)
  (list (open-file-action (row-path row))))

(define (enter-command ed state ps vid)
  (define row (current-row ed state ps vid))
  (cond
    [(not (filetree-state? ps)) (values state ps '())]
    [(not row) (values state ps '())]
    [(eq? (row-kind row) 'file)
     (values state ps (open-row-action row))]
    [(memq (row-kind row) '(root dir))
     (define path (row-path row))
     (define expanded
       (if (hash-ref (filetree-state-expanded ps) path #f)
           (hash-remove (filetree-state-expanded ps) path)
           (hash-set (filetree-state-expanded ps) path #t)))
     (values state
             (refresh-state (struct-copy filetree-state ps [expanded expanded]) path)
             '())]
    [else (values state ps '())]))

(define (find-command ed state ps vid)
  (cond
    [(not (filetree-state? ps)) (values state ps '())]
    [else
     (values state ps
             (list (filetree-find-action
                    (or (filetree-state-find-query ps) ""))))]))

(define (clear-find-command ed state ps vid)
  (cond
    [(not (filetree-state? ps)) (values state ps '())]
    [else
     (values (state-with-flash state "filetree find cleared")
             (filetree-clear-find! ps)
             '())]))

(define (find-step-command ed state ps step)
  (define matches (and (filetree-state? ps)
                       (filetree-state-find-matches ps)))
  (cond
    [(not (filetree-state? ps)) (values state ps '())]
    [(null? matches)
     (if (filetree-state-find-query ps)
         (values (state-with-flash state "find: no matches") ps '())
         (values state ps '()))]
    [else
     (define n (length matches))
     (define idx (modulo (+ (filetree-state-find-index ps) step) n))
     (define path (list-ref matches idx))
     (values (state-with-flash state (format "find ~a/~a" (add1 idx) n))
             (struct-copy filetree-state ps
                          [find-index idx]
                          [expanded (expand-parents (filetree-state-expanded ps)
                                                    (filetree-state-root ps)
                                                    path)]
                          [stale? #t]
                          [pending-cursor path])
             '())]))

(define (refresh-command ed state ps vid)
  (define row (current-row ed state ps vid))
  (cond
    [(not (filetree-state? ps)) (values state ps '())]
    [else
     (values (state-with-flash state "filetree refreshed")
             (refresh-state ps (and row (row-path row)))
             '())]))

(define (toggle-hidden-command ed state ps vid)
  (define row (current-row ed state ps vid))
  (cond
    [(not (filetree-state? ps)) (values state ps '())]
    [else
     (define ps* (struct-copy filetree-state ps
                              [show-hidden? (not (filetree-state-show-hidden? ps))]))
     (values state (refresh-state ps* (and row (row-path row))) '())]))

(define (row-parent-directory ps row)
  (define p (row-path row))
  (case (row-kind row)
    [(root dir) p]
    [(file) (or (path-only p) (filetree-state-root ps))]
    [else (filetree-state-root ps)]))

(define (create-command ed state ps vid kind)
  (define row (current-row ed state ps vid))
  (cond
    [(not row) (values (state-with-flash state "filetree: no line") ps '())]
    [else
     (values state ps
             (list (filetree-create-action
                    (row-parent-directory ps row) kind)))]))

(define (delete-command ed state ps vid)
  (define row (current-row ed state ps vid))
  (cond
    [(not row) (values (state-with-flash state "filetree: no line") ps '())]
    [(memq (row-kind row) '(file dir))
     (values state ps
             (list (filetree-delete-action (row-path row) (row-kind row))))]
    [else (values (state-with-flash state "filetree: cannot delete root") ps '())]))

(define (rename-command ed state ps vid)
  (define row (current-row ed state ps vid))
  (cond
    [(not row) (values (state-with-flash state "filetree: no line") ps '())]
    [(memq (row-kind row) '(file dir))
     (values state ps
             (list (filetree-rename-action (row-path row) (row-kind row))))]
    [else (values (state-with-flash state "filetree: cannot rename root") ps '())]))

;;; ════════════════ plugin ════════════════

(define (make-filetree-plugin #:view vid #:root root
                              #:hidden-entry? [hidden-entry? default-hidden-entry?])
  (define root* (simplify-path (path->complete-path root)))
  (make-plugin
   #:id 'filetree
   #:state (filetree-state root* vid (hash root* #t) #f '() #t #f #f #f #f #f '() 0 #f)
   #:command-scope 'filetree
   #:view-scopes (hash vid 'filetree)
   #:commands
   (keys
    [(key 'enter)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (enter-command ed state ps vid)))]
    [(key 'escape)
     (make-guarded-command
      #:when (λ (ed state ps)
               (and (filetree-focused? state vid)
                    (filetree-state? ps)
                    (or (filetree-state-find-query ps)
                        (pair? (filetree-state-find-matches ps)))))
      #:run (λ (ed state ps) (clear-find-command ed state ps vid)))]
    [(key 'left 'ctrl)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (find-step-command ed state ps -1)))]
    [(key 'right 'ctrl)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (find-step-command ed state ps 1)))]
    [(key 'r 'ctrl)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (refresh-command ed state ps vid)))]
    [(key 'h 'ctrl)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (toggle-hidden-command ed state ps vid)))]
    [(key 'f 'ctrl) (key 's)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (find-command ed state ps vid)))]
    [(key 'f 'ctrl) (key 'n)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (create-command ed state ps vid 'file)))]
    [(key 'f 'ctrl) (key 'f 'ctrl) (key 'n)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (create-command ed state ps vid 'dir)))]
    [(key 'f 'ctrl) (key 'd)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (delete-command ed state ps vid)))]
    [(key 'f 'ctrl) (key 'r)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (rename-command ed state ps vid)))]
    [(key 'f 'ctrl) (key 'l)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (refresh-command ed state ps vid)))])
   #:sync (make-sync-filetree hidden-entry?)
   #:services (list (make-filetree-scan-service hidden-entry?)
                    (make-filetree-search-service hidden-entry?))
   #:handle-job handle-filetree-job))

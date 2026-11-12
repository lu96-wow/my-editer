#lang racket

;;; edit-tui-rebuild/plugins/filetree/plugin.rkt —— 文件树
;;;
;;; 当前能力：
;;;   · root / 目录 / 文件 行投影
;;;   · 用两空格缩进 + face（root / dir / open / file）区分层次和类型
;;;   · 目录展开 / 折叠
;;;   · 隐藏 dotfile 的显示 / 隐藏
;;;   · C-f n / C-f C-f n / C-f d / C-f r -> create/delete/rename action（IO 在 host）
;;;   · C-f l / C-r 重扫
;;;   · Enter 打开文件 -> open-file-action
;;;
;;; 插件状态是纯值：root / view / expanded / show-hidden? / rows / pending-cursor。
;;; 目录扫描在 sync 阶段做；C-r / 展开 / 隐藏只把 rows 置空，下一次 sync 重扫。
;;; 回调用当前 ps 读写自己的状态；跨插件 / host 请求用 action。

(require racket/file
         (only-in racket/list append*)
         racket/path
         racket/string
         "../../core/command/api.rkt"
         "../../editor/api.rkt")

(provide make-filetree-plugin
         (struct-out filetree-state))

(struct filetree-state
  (root
   view
   expanded      ; hash path -> #t
   show-hidden?  ; bool
   rows          ; (listof row)
   stale?        ; #t = 需要重扫
   pending       ; #f | 正在后台扫描的 projection tag
   pending-cursor) ; #f | path：sync 后把光标放到该 path 的行
  #:transparent)

;; row = (list path kind text depth)
(define (row-path row) (car row))
(define (row-kind row) (cadr row))
(define (row-text row) (caddr row))
(define (row-depth row) (cadddr row))

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

(define (handle-filetree-job ed state ps ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'filetree-scan)) (values state ps '())]
    [(not (filetree-state? ps)) (values state ps '())]
    [else
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
                '())])]))

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

(define (make-sync-filetree hidden-entry?)
  (λ (ed state ps)
    (cond
      [(not (filetree-state? ps)) (values state ps)]
      [else
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
                                   (filetree-state-rows ps1)))])])))

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

(define (enter-command ed state ps vid)
  (define row (current-row ed state ps vid))
  (cond
    [(not row) (values state ps '())]
    [(eq? (row-kind row) 'file)
     (values state ps (list (open-file-action (row-path row))))]
    [(memq (row-kind row) '(root dir))
     (cond
       [(not (filetree-state? ps)) (values state ps '())]
       [else
        (define path (row-path row))
        (define expanded
          (if (hash-ref (filetree-state-expanded ps) path #f)
              (hash-remove (filetree-state-expanded ps) path)
              (hash-set (filetree-state-expanded ps) path #t)))
        (values state
                (refresh-state (struct-copy filetree-state ps [expanded expanded]) path)
                '())])]
    [else (values state ps '())]))

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

(define (make-filetree-plugin #:view vid #:root root
                              #:hidden-entry? [hidden-entry? default-hidden-entry?])
  (define root* (simplify-path (path->complete-path root)))
  (make-plugin
   #:id 'filetree
   #:state (filetree-state root* vid (hash root* #t) #f '() #t #f #f)
   #:command-scope 'filetree
   #:commands
   (keys
    [(key 'enter)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (enter-command ed state ps vid)))]
    [(key 'r 'ctrl)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (refresh-command ed state ps vid)))]
    [(key 'h 'ctrl)
     (make-guarded-command
      #:when (λ (ed state ps) (filetree-focused? state vid))
      #:run (λ (ed state ps) (toggle-hidden-command ed state ps vid)))]
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
   #:services (list (make-filetree-scan-service hidden-entry?))
   #:handle-job handle-filetree-job))

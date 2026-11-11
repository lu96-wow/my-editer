#lang racket

;;; edit-tui-rebuild/plugins/filetree/plugin.rkt —— 文件树
;;;
;;; 当前能力：
;;;   · root / 目录 / 文件 行投影
;;;   · 用两空格缩进 + face（root / dir / open / file）区分层次和类型
;;;   · 目录展开 / 折叠
;;;   · 隐藏 dotfile 的显示 / 隐藏
;;;   · C-r 重扫
;;;   · Enter 打开文件 -> open-file-action
;;;
;;; 插件状态是纯值：root / view / expanded / show-hidden? / rows / pending-cursor。
;;; 目录扫描在 sync 阶段做；C-r / 展开 / 隐藏只把 rows 置空，下一次 sync 重扫。

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

(define (handle-filetree-job ed state ev)
  (cond
    [(not (eq? (job-result-event-kind ev) 'filetree-scan)) state]
    [else
     (define st (editor-state-plugin-state state 'filetree))
     (cond
       [(not (filetree-state? st)) state]
       [else
        (define tag (job-result-event-tag ev))
        (define result (job-result-event-result ev))
        (define current-tag (projection-tag st))
        (cond
          [(job-error? result)
           (editor-state-set-plugin-state
            (editor-state-with-flash state "filetree scan failed")
            'filetree
            (struct-copy filetree-state st [pending #f] [stale? #f]))]
          [(equal? tag current-tag)
           (editor-state-set-plugin-state
            state 'filetree
            (struct-copy filetree-state st
                         [rows result]
                         [pending #f]
                         [stale? #f]))]
          [else
           ;; 扫描期间投影又变了：丢掉旧结果，下一帧重新提交。
           (editor-state-set-plugin-state
            state 'filetree
            (struct-copy filetree-state st [pending #f]))])])]))

(define (write-filetree! ed state st rows)
  (define engine (editor-engine ed))
  (define vid (filetree-state-view st))
  (define opened (editor-state-opened-paths state))
  (engine-set-view-content! engine vid
                           (map row-text rows)
                           (map (λ (row) (row-face row opened)) rows))
  (define pending (filetree-state-pending-cursor st))
  (cond
    [(not pending) (struct-copy filetree-state st [rows rows])]
    [else
     (define line (find-line rows pending))
     (cond
       [line
        (engine-set-view-cursor! engine vid line #:column 0)
        (struct-copy filetree-state st [rows rows] [pending-cursor #f])]
       [else (struct-copy filetree-state st [rows rows])])]))

(define (make-sync-filetree hidden-entry?)
  (λ (ed state)
  (define st (editor-state-plugin-state state 'filetree))
  (cond
    [(not (filetree-state? st)) state]
    [else
     (define root (filetree-state-root st))
     (define expanded (filetree-state-expanded st))
     (define show-hidden? (filetree-state-show-hidden? st))
     (define tag (projection-tag st))
     (cond
       [(not (editor-state-async? state))
        (define rows
          (if (filetree-state-stale? st)
              (scan-tree root expanded show-hidden? hidden-entry?)
              (filetree-state-rows st)))
        (define st* (write-filetree! ed state st rows))
        (editor-state-set-plugin-state
         state 'filetree
         (struct-copy filetree-state st* [stale? #f] [pending #f]))]
       [else
        (define-values (base-state st1)
          (cond
            [(and (filetree-state-stale? st)
                  (not (filetree-state-pending st)))
             (define-values (state* _job)
               (editor-state-submit-job state 'filetree-scan tag tag))
             (values state* (struct-copy filetree-state st [pending tag]))]
            [else (values state st)]))
        (define st2 (write-filetree! ed base-state st1 (filetree-state-rows st1)))
        (editor-state-set-plugin-state base-state 'filetree st2)])])))

(define (filetree-focused? state vid)
  (eq? (editor-focus-view-id state) vid))

(define (current-row ed state vid)
  (define st (editor-state-plugin-state state 'filetree))
  (define rows (and (filetree-state? st) (filetree-state-rows st)))
  (define line (engine-view-point-line (editor-engine ed) vid))
  (and rows line (< line (length rows)) (list-ref rows line)))

(define (refresh-state state st path)
  (editor-state-set-plugin-state
   state 'filetree
   (struct-copy filetree-state st
                [stale? #t]
                [pending-cursor path])))

(define (enter-command ed state vid)
  (define row (current-row ed state vid))
  (cond
    [(not row) (values state '())]
    [(eq? (row-kind row) 'file)
     (values state (list (open-file-action (row-path row))))]
    [(memq (row-kind row) '(root dir))
     (define st (editor-state-plugin-state state 'filetree))
     (define path (row-path row))
     (define expanded
       (if (hash-ref (filetree-state-expanded st) path #f)
           (hash-remove (filetree-state-expanded st) path)
           (hash-set (filetree-state-expanded st) path #t)))
     (define st* (struct-copy filetree-state st [expanded expanded]))
     (values (refresh-state state st* path) '())]
    [else (values state '())]))

(define (refresh-command ed state vid)
  (define st (editor-state-plugin-state state 'filetree))
  (define row (current-row ed state vid))
  (cond
    [(not (filetree-state? st)) (values state '())]
    [else
     (values (editor-state-with-flash
              (refresh-state state st (and row (row-path row)))
              "filetree refreshed")
             '())]))

(define (toggle-hidden-command ed state vid)
  (define st (editor-state-plugin-state state 'filetree))
  (define row (current-row ed state vid))
  (cond
    [(not (filetree-state? st)) (values state '())]
    [else
     (define st* (struct-copy filetree-state st
                              [show-hidden? (not (filetree-state-show-hidden? st))]))
     (values (refresh-state state st* (and row (row-path row)))
             '())]))

(define (make-filetree-plugin #:view vid #:root root
                              #:hidden-entry? [hidden-entry? default-hidden-entry?])
  (define root* (simplify-path (path->complete-path root)))
  (make-plugin
   #:id 'filetree
   #:state (filetree-state root* vid (hash root* #t) #f '() #t #f #f)
   #:commands
   (keys
    [(key 'enter)
     (make-guarded-command
      #:when (λ (ed state) (filetree-focused? state vid))
      #:run (λ (ed state) (enter-command ed state vid)))]
    [(key 'r 'ctrl)
     (make-guarded-command
      #:when (λ (ed state) (filetree-focused? state vid))
      #:run (λ (ed state) (refresh-command ed state vid)))]
    [(key 'h 'ctrl)
     (make-guarded-command
      #:when (λ (ed state) (filetree-focused? state vid))
      #:run (λ (ed state) (toggle-hidden-command ed state vid)))])
   #:sync (make-sync-filetree hidden-entry?)
   #:services (list (make-filetree-scan-service hidden-entry?))
   #:handle-job handle-filetree-job))

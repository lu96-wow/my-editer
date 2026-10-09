#lang racket

;;; edit/feature/tree.rkt —— 文件树窗口（渲染 + 组合资源能力）
;;;
;;; 状态：core/tree-state.rkt 的纯导航状态机，放本模块闭包的 box。
;;; I/O：read-dir 来自 document/fs.rkt（资源侧）。
;;; 渲染：tree-rows -> panel-doc；face 走主题（tree-dir/file/link/hidden/open/match/current）。
;;;
;;; **更新只提供能力**：tree-refresh / tree-refresh-dir / tree-invalidate 都在 core，
;;; 何时刷新由外部（命令发起者）决定；渲染只用缓存，不碰磁盘。

(require racket/path
         "api.rkt"
         "../core/tree-state.rkt"
         "../document/fs.rkt"
         "../document/document.rkt")   ; 打开文件（资源命令）

(provide tree-install
         (struct-out cmd-tree-activate) (struct-out cmd-tree-new-file)
         (struct-out cmd-tree-new-dir) (struct-out cmd-tree-delete)
         (struct-out cmd-tree-refresh) (struct-out cmd-tree-toggle)
         (struct-out cmd-tree-search) (struct-out cmd-tree-search-next)
         (struct-out cmd-tree-search-prev) (struct-out cmd-tree-search-clear))

(define (norm p) (simplify-path (path->complete-path p)))
(define (path=? a b) (equal? (norm a) (norm b)))

;; 执行会读盘的树操作（可能抛文件系统异常）：成功写入 st 并返回会话；
;; 失败 → 记日志（不弹出则已由 prompt 规则决定）、树状态不变。
(define (tree-read! s st thunk)
  (with-handlers ([exn:fail? (lambda (e) (session-log! s (format "tree: ~a" (exn-message e))))])
    (set-box! st (thunk))
    s))

;;; ---------- 文档（渲染） ----------

(define (entry-line e)
  (string-append (make-string (* 2 (entry-depth e)) #\space)
                 (entry-name e)
                 (if (entry-dir? e) "/" "")))

(define (open-paths s)
  (for/list ([d (in-list (session-file-dids s))] #:when (session-file-path s d))
    (session-file-path s d)))

(define (entry-face st e opens)
  (define p (entry-path e))
  (cond
    [(let ([c (tree-search-current st)]) (and c (path=? c p))) 'tree-current]
    [(tree-search-match? st p) 'tree-match]
    [(entry-hidden? e) 'tree-hidden]
    [(entry-link? e) 'tree-link]
    [(and (not (entry-dir? e)) (for/or ([o (in-list opens)]) (path=? o p))) 'tree-open]
    [(entry-dir? e) 'tree-dir]
    [else 'tree-file]))

(define (tree-document st opens)
  (panel-doc
   (for/list ([e (in-list (tree-rows st))])
     (list (entry-line e) (entry-face st e opens)))))

;; panel refresh：内容没变就 #f。
(define (make-refresh st)
  (define last (box #f))
  (lambda (s)
    (define opens (open-paths s))
    (define key (list (tree-rows (unbox st)) (tree-search-current (unbox st)) opens))
    (cond [(equal? key (unbox last)) #f]
          [else (set-box! last key) (tree-document (unbox st) opens)])))

;;; ---------- 命令 ----------

(struct cmd-tree-activate      ()     #:transparent)
(struct cmd-tree-new-file      ()     #:transparent)
(struct cmd-tree-new-dir       ()     #:transparent)
(struct cmd-tree-delete        ()     #:transparent)
(struct cmd-tree-refresh       ()     #:transparent)
(struct cmd-tree-toggle        ()     #:transparent)
(struct cmd-tree-search        (text) #:transparent)
(struct cmd-tree-search-next   ()     #:transparent)
(struct cmd-tree-search-prev   ()     #:transparent)
(struct cmd-tree-search-clear  ()     #:transparent)

(define (entry-at-focus s st vid)
  (define line (session-view-point-line s vid))
  (define rows (tree-rows (unbox st)))
  (and (< line (length rows)) (list-ref rows line)))

(define (goto-current! s st vid)
  (define p (tree-search-current (unbox st)))
  (cond
    [(not p) s]
    [else (define i (tree-row-index (unbox st) p))
          (if i (session-ed-set-point! s vid i 0) s)]))

(define (do-activate s st vid)
  (define e (entry-at-focus s st vid))
  (cond
    [(not e) s]
    [(entry-dir? e)
     (tree-read! s st (lambda () (tree-toggle (unbox st) (entry-path e) fs-read-dir)))]
    ;; 文件：发资源命令；由 document handler 读盘打开（带默认命令表）。
    [else (step s (cmd-open-file-path (entry-path e)))]))

(define (do-search s st vid text)
  (define s1 (tree-read! s st (lambda () (tree-search-set (unbox st) text fs-read-dir))))
  ;; 先让 panel document 反映新状态，光标才能落到新行
  (session-refresh s1)
  (goto-current! s1 st vid))

(define (do-search-step s st vid dir)
  (define s1 (tree-read! s st
                         (lambda ()
                           (if (> dir 0)
                               (tree-search-next (unbox st) fs-read-dir)
                               (tree-search-prev (unbox st) fs-read-dir)))))
  (session-refresh s1)
  (goto-current! s1 st vid))

;;; ---------- 新建 / 删除（资源操作） ----------

;; 新建目标目录：目录项→自身；文件项→父；无焦点→根。
(define (target-dir st e)
  (cond
    [(not e) (tree-state-root st)]
    [(entry-dir? e) (entry-path e)]
    [else (path-only (entry-path e))]))

;; 目录内容变了：丢缓存 → 重读并展开 →（可选）reveal 新路径。→ session
(define (tree-after-change s st dir [reveal #f])
  (tree-read! s st
    (lambda ()
      (define t (tree-invalidate (unbox st) dir))
      (define t2 (tree-expand t dir fs-read-dir))
      (if reveal (tree-reveal t2 reveal fs-read-dir) t2))))

(define (do-new-file s st vid)
  (define dir (target-dir (unbox st) (entry-at-focus s st vid)))
  (session-prompt-open s (session-panel-vid s 'input) "new file: "
    (lambda (s name)
      (cond
        [(zero? (string-length name)) s]
        [else (define-values (s1 p) (session-new-file s dir name))
              (if p (tree-after-change s1 st dir p) s1)]))))

(define (do-new-dir s st vid)
  (define dir (target-dir (unbox st) (entry-at-focus s st vid)))
  (session-prompt-open s (session-panel-vid s 'input) "new folder: "
    (lambda (s name)
      (cond
        [(zero? (string-length name)) s]
        [else (define-values (s1 p) (session-new-dir s dir name))
              (if p (tree-after-change s1 st dir p) s1)]))))

(define (do-delete s st vid)
  (define e (entry-at-focus s st vid))
  (cond
    [(not e) s]
    [else
     (define p (entry-path e))
     (define parent (path-only p))
     (session-prompt-open s (session-panel-vid s 'input)
       (format "delete ~a? (y/n) " (entry-name e))
       (lambda (s ans)
         (if (and (positive? (string-length ans))
                  (char=? (char-downcase (string-ref ans 0)) #\y))
             (tree-after-change (session-delete-path s p) st parent)
             s)))]))

(define (tree-handler st vid)
  (lambda (s cmd)
    (cond
      [(cmd-tree-activate? cmd) (do-activate s st vid)]
      [(cmd-tree-new-file? cmd) (do-new-file s st vid)]
      [(cmd-tree-new-dir? cmd)  (do-new-dir s st vid)]
      [(cmd-tree-delete? cmd)   (do-delete s st vid)]
      ;; 更新能力：外部（命令发起者）决定何时刷新。
      [(cmd-tree-refresh? cmd)
       (tree-read! s st (lambda () (tree-refresh (unbox st) fs-read-dir)))]
      [(cmd-tree-toggle? cmd) (session-set-visible s vid (not (session-visible? s vid)))]
      [(cmd-tree-search? cmd) (do-search s st vid (cmd-tree-search-text cmd))]
      [(cmd-tree-search-next? cmd) (do-search-step s st vid 1)]
      [(cmd-tree-search-prev? cmd) (do-search-step s st vid -1)]
      [(cmd-tree-search-clear? cmd) (set-box! st (tree-search-clear (unbox st))) s]
      [else #f])))

;;; ---------- 装配 ----------

(define tree-keys
  (kbd
   (key 'up)        (cmd-nav 'up #f)
   (key 'down)      (cmd-nav 'down #f)
   (key 'enter)     (cmd-tree-activate)
   (key 'n 'ctrl)   (cmd-tree-new-file)
   (key 'l 'ctrl)   (cmd-tree-new-dir)
   (key 'backspace) (cmd-tree-delete)
   (key 'escape)    (cmd-tree-toggle)
   (key 'tab)       (cmd-panel-swap)))

;; → (values session vid)
(define (tree-install s root width height)
  (define-values (s1 _did vid) (session-add-document s "" width height #:name "*tree*"))
  (define-values (s2 st)
    (with-handlers ([exn:fail? (lambda (e)
                                 (values (session-log! s1 (format "tree: ~a" (exn-message e)))
                                         (box (tree-state (norm root) (hash) (hash) #f))))])
      (values s1 (box (tree-state-open root fs-read-dir)))))
  (define p (panel 'tree vid (make-refresh st) tree-keys 'left 1))
  (define s3 (session-add-panel s2 p))
  (values (session-add-handler s3 (tree-handler st vid)) vid))

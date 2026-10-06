#lang racket

(require racket/file
         racket/path
         "../../core/editor.rkt"
         "../platform/path.rkt"
         "../platform/state.rkt"
         "../platform/panes.rkt"
         "../platform/panel.rkt"
         "../platform/paths.rkt"
         "../platform/input.rkt"
         "../platform/keymap.rkt"
         "../platform/command.rkt"
         "../platform/hooks.rkt"
         "edit.rkt")

;;; lab-rebuild/builtin/tree.rkt —— 文件树面板（内置包）
;;;
;;; 全部通过平台扩展点接入，不 require app / render：
;;;   · panel-provider-register!  注册左栏面板
;;;   · keymap-define             注册该面板文档的 per-did 键表
;;;   · define-command            注册 Enter / 新建 / 删除命令
;;;   · app-begin! / app-open-path! （内置编辑包提供的动作）
;;;
;;; 树本身是一篇只读 document：core 的渲染 / 选区 / 滚动全套照用。
;;; 行 ↔ 条目用行号查 tree-entries。

(provide make-tree-panel tree-panel-refresh! tree-entry-at-focus
         ;; 模型（可测）
         (struct-out entry)
         file-tree? file-tree-root file-tree-expanded
         file-tree file-tree-toggle! file-tree-expand! file-tree-collapse!
         tree-entries tree-entry-count tree-line->entry tree-line->path
         tree->lines tree->document tree-refresh!
         tree-create-file! tree-create-dir! tree-delete-path!
         tree-face-dir tree-face-file tree-face-link tree-face-hidden tree-face-open)

;;; ================= 模型 =================

(struct entry (path name dir? link? depth) #:transparent)

(struct file-tree% (root expanded) #:mutable #:transparent)
(define (file-tree? x) (file-tree%? x))
(define (file-tree-root t) (file-tree%-root t))
(define (file-tree-expanded t) (file-tree%-expanded t))

(define (file-tree root [expand-root? #t])
  (define r (simplify-path (path->complete-path root)))
  (define t (file-tree% r (make-hash)))
  (when expand-root? (hash-set! (file-tree%-expanded t) r #t))
  t)

(define (tree-expanded? t p)
  (and (hash-ref (file-tree-expanded t) (simplify-path p) #f) #t))
(define (file-tree-expand! t p) (hash-set! (file-tree-expanded t) (simplify-path p) #t) (void))
(define (file-tree-collapse! t p) (hash-remove! (file-tree-expanded t) (simplify-path p)) (void))
(define (file-tree-toggle! t p)
  (define np (simplify-path p))
  (if (hash-ref (file-tree-expanded t) np #f)
      (hash-remove! (file-tree-expanded t) np)
      (hash-set! (file-tree-expanded t) np #t))
  (void))

;;; ---------- 扫描 ----------

(define (entry-of p depth)
  (define np (simplify-path p))
  (entry np (basename np) (directory-exists? np) (link-exists? np) depth))

(define (sorted-children dir)
  (sort (directory-list dir #:build? #t)
        (lambda (a b)
          (define da (and (directory-exists? a) #t))
          (define db (and (directory-exists? b) #t))
          (cond [(and da (not db)) #t]
                [(and db (not da)) #f]
                [else (string<? (basename a) (basename b))]))))

(define (tree-entries t)
  (define (node p depth)
    (define e (entry-of p depth))
    (if (and (entry-dir? e) (tree-expanded? t p))
        (cons e (append* (for/list ([c (in-list (sorted-children p))]) (node c (add1 depth)))))
        (list e)))
  (node (file-tree-root t) 0))

(define (tree-entry-count t) (length (tree-entries t)))

;;; ================= face =================

(define tree-face-dir 'tree-dir)
(define tree-face-file 'tree-file)
(define tree-face-link 'tree-link)
(define tree-face-hidden 'tree-hidden)
(define tree-face-open 'tree-open)

(define (hidden-name? nm)
  (and (> (string-length nm) 0) (char=? (string-ref nm 0) #\.)))

(define (default-entry-face e open?)
  (cond [(and open? (not (entry-dir? e))) tree-face-open]
        [(hidden-name? (entry-name e)) tree-face-hidden]
        [(entry-link? e) tree-face-link]
        [(entry-dir? e) tree-face-dir]
        [else tree-face-file]))

;;; ================= 模型 → document =================

(define (entry-line-text e indent)
  (string-append (make-string (* indent (entry-depth e)) #\space) (entry-name e)))

(define (tree->lines t [indent 2] [face-of default-entry-face]
                     #:open? [open? (lambda (p) #f)])
  (for/list ([e (in-list (tree-entries t))])
    (list (entry-line-text e indent) (face-of e (open? (entry-path e))))))

(define (tree->document t
                        #:indent [indent 2]
                        #:face-of [face-of default-entry-face]
                        #:open? [open? (lambda (p) #f)]
                        #:readonly? [readonly? #t])
  (define lines (tree->lines t indent face-of #:open? open?))
  (define text (string-join (for/list ([ln (in-list lines)]) (first ln)) "\n"))
  (define doc (document-open text))
  (document-highlight-fill-batch
   doc (for/list ([ln (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length (first ln)) (second ln))))
  (when readonly?
    (document-readonly-fill-batch
     doc (for/list ([ln (in-list lines)] [i (in-naturals)])
           (list i 0 i (string-length (first ln)) #t))))
  doc)

(define (tree-refresh! ed vid t
                       #:indent [indent 2]
                       #:face-of [face-of default-entry-face]
                       #:open? [open? (lambda (p) #f)]
                       #:readonly? [readonly? #t])
  (editor-view-assign! ed vid (tree->document t
                                              #:indent indent #:face-of face-of
                                              #:open? open? #:readonly? readonly?))
  (void))

;;; ================= 行 → entry / path =================

(define (tree-line->entry t line)
  (define es (tree-entries t))
  (and (exact-nonnegative-integer? line) (< line (length es)) (list-ref es line)))

(define (tree-line->path t line)
  (define e (tree-line->entry t line))
  (and e (entry-path e)))

;;; ================= 文件系统操作 =================

(define (tree-create-file! dir name)
  (define p (simplify-path (build-path dir name)))
  (and (not (file-exists? p))
       (begin (call-with-output-file p #:exists 'error (lambda (out) (void))) p)))

(define (tree-create-dir! dir name)
  (define p (simplify-path (build-path dir name)))
  (and (not (file-exists? p))
       (begin (make-directory p) p)))

(define (tree-delete-path! p)
  (define np (simplify-path p))
  (cond [(directory-exists? np) (delete-directory/files np)]
        [else (delete-file np)])
  (void))

;;; ================= 动作 =================

(define (tree-entry-at-focus a)
  (define p (app-panel a 'tree))
  (and p (tree-line->entry (panel-data p)
                           (editor-view-point-line (app-ed a) (panel-vid p)))))

(define (tree-panel-refresh! a)
  (define p (app-panel a 'tree))
  (when p
    (tree-refresh! (app-ed a) (panel-vid p) (panel-data p)
                   #:open? (lambda (path) (path-table-open? (app-paths a) path)))))

(define (app-tree-activate! a)
  (define e (tree-entry-at-focus a))
  (define p (app-panel a 'tree))
  (cond [(not e) (void)]
        [(entry-dir? e) (file-tree-toggle! (panel-data p) (entry-path e)) (tree-panel-refresh! a)]
        [else (app-open-path! a (entry-path e))]))

(define (app-target-dir a)
  (define e (tree-entry-at-focus a))
  (define root (file-tree-root (panel-data (app-panel a 'tree))))
  (cond [(not e) root]
        [(entry-dir? e) (entry-path e)]
        [else (let-values ([(base _name _dir?) (split-path (entry-path e))]) base)]))

(define (app-tree-new-file! a)
  (define target (app-target-dir a))
  (app-begin! a "new file: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-file! target name))
                  (file-tree-expand! (panel-data (app-panel a 'tree)) target)
                  (tree-panel-refresh! a)))))

(define (app-tree-new-dir! a)
  (define target (app-target-dir a))
  (app-begin! a "new folder: " #t
              (lambda (name)
                (when (and (positive? (string-length name)) (tree-create-dir! target name))
                  (file-tree-expand! (panel-data (app-panel a 'tree)) target)
                  (tree-panel-refresh! a)))))

(define (app-tree-delete! a)
  (define e (tree-entry-at-focus a))
  (when e
    (define p (entry-path e))
    (app-begin! a (format "delete ~a? (y/n)" (entry-name e)) #f
                (lambda (yes?)
                  (when yes?
                    (tree-delete-path! p)
                    ;; 盘上已删：强制关（不再弹保存，否则会把它写回来）。
                    (app-close-path! a p #:save? #f)
                    (tree-panel-refresh! a))))))

;;; ================= 键表 + 命令 =================

(define tree-keys
  (keymap-define 'tree
   (key 'tab)       'toggle-left
   (key 'enter)     'tree-activate
   (key 'n 'ctrl)   'tree-new-file
   (key 'l 'ctrl)   'tree-new-dir
   (key 'backspace) 'tree-delete))

(define (cmd-tree-activate e a) (app-tree-activate! a))
(define (cmd-tree-new-file e a) (app-tree-new-file! a))
(define (cmd-tree-new-dir e a)  (app-tree-new-dir! a))
(define (cmd-tree-delete e a)   (app-tree-delete! a))

(define-command tree-activate cmd-tree-activate)
(define-command tree-new-file cmd-tree-new-file)
(define-command tree-new-dir  cmd-tree-new-dir)
(define-command tree-delete    cmd-tree-delete)

;;; ================= 面板 provider =================

(define (make-tree-panel ctx)
  (define root (panel-context-root ctx))
  (define ed (panel-context-ed ctx))
  (define t (file-tree root))
  (define doc (tree->document t))
  (define-values (ed2 _did vid)
    (editor-add-document-view ed doc (panel-context-width ctx) (panel-context-height ctx) "*tree*"))
  (values ed2
          (panel 'tree vid tree-keys t
                 (lambda (a)
                   (define (refresh app . _) (tree-panel-refresh! app))
                   (hook-add! a 'document-opened refresh)
                   (hook-add! a 'document-closed refresh)
                   (tree-panel-refresh! a)))))

(void (panel-provider-register! make-tree-panel))

#lang racket

;;; lab-re-rebuild/builtin/tree.rkt —— 文件树（left dock）。
;;;
;;; 「逻辑独立」：目录模型（展开集）/ 列举 / 键位 / 新建 / 删除全在本模块；
;;; kernel 只提供 dock 机制。打开文件发 e-file-open（document.rkt）；输入发 e-prompt（effect 语言）。
;;;
;;; 树本身是一篇只读 document，core 的渲染 / 选区 / 滚动全套照用。

(require racket/string
         racket/file
         racket/path
         "../kernel/api.rkt"
         "../config/keys.rkt"
         "document.rkt"
         "document-api.rkt")

(provide register-tree! (struct-out entry) (struct-out file-tree) tree-entries entry-face)

;;; ================= 模型 =================

(struct entry (path name dir? link? depth) #:transparent)
(struct file-tree (root expanded) #:mutable #:transparent)
;; expanded : hash 规范化路径 -> #t

(define (basename p)
  (path->string (or (file-name-from-path (path->complete-path p)) p)))

(define (tree-expanded? t p) (and (hash-ref (file-tree-expanded t) (simplify-path p) #f) #t))
(define (file-tree-expand! t p) (hash-set! (file-tree-expanded t) (simplify-path p) #t) (void))
(define (file-tree-toggle! t p)
  (define np (simplify-path p))
  (if (hash-ref (file-tree-expanded t) np #f)
      (hash-remove! (file-tree-expanded t) np)
      (hash-set! (file-tree-expanded t) np #t))
  (void))

(define (make-tree-model root)
  (define r (simplify-path (path->complete-path root)))
  (file-tree r (make-hash (list (cons r #t)))))

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

;;; ================= 文档 =================

(define (entry-line-text e indent)
  (string-append (make-string (* indent (entry-depth e)) #\space)
                 (entry-name e)
                 (if (entry-dir? e) "/" "")))

(define (hidden-name? nm)
  (and (> (string-length nm) 0) (char=? (string-ref nm 0) #\.)))

(define (entry-face e open?)
  (cond [(and open? (not (entry-dir? e))) 'tree-open]
        [(hidden-name? (entry-name e)) 'tree-hidden]
        [(entry-link? e) 'tree-link]
        [(entry-dir? e) 'tree-dir]
        [else 'tree-file]))

(define (tree->document t #:open? [open? (lambda (p) #f)])
  (define rows (for/list ([e (in-list (tree-entries t))])
                 (list (entry-line-text e 2) (entry-face e (open? (entry-path e))))))
  (define text (if (null? rows) "" (string-join (for/list ([r (in-list rows)]) (first r)) "\n")))
  (define doc (document-open text))
  (document-face-fill-batch
   doc (for/list ([r (in-list rows)] [i (in-naturals)])
         (list i 0 i (string-length (first r)) (second r))))
  (document-readonly-fill-batch
   doc (for/list ([r (in-list rows)] [i (in-naturals)])
         (list i 0 i (string-length (first r)) #t)))
  doc)

;;; ================= 文件系统操作 =================

(define (tree-create-file! dir name)
  (define p (simplify-path (build-path dir name)))
  (and (not (file-exists? p))
       (begin (call-with-output-file p #:exists 'error (lambda (out) (void))) p)))

(define (tree-create-dir! dir name)
  (define p (simplify-path (build-path dir name)))
  (and (not (file-exists? p)) (begin (make-directory p) p)))

(define (tree-delete-path! p)
  (define np (simplify-path p))
  (cond [(directory-exists? np) (delete-directory/files np)]
        [else (delete-file np)])
  (void))

;;; ================= dock 装配 =================

(define (tree-make root ed w h)
  (define-values (ed2 _did vid) (editor-add-document-view ed (document-open "") w h "*tree*"))
  (values ed2 vid))

(define tree-keys
  (keytable-merge
   (list dock-base
         (kbd (key 'enter)     'tree-activate
              (key 'up)        '(nav up #f)
              (key 'down)      '(nav down #f)
              (key 'n 'ctrl)   'tree-new-file
              (key 'l 'ctrl)   'tree-new-dir
              (key 'backspace) 'tree-delete
              (key 'escape)    'tree-toggle))))

(define tree-spec (dock-spec 'tree 'left 24 #f tree-make tree-keys))

(define (tree-model ctx) (service-ref ctx 'tree-model))
(define (tree-init ctx)
  (service-put ctx 'tree-model (make-tree-model (or (service-ref ctx 'root) (current-directory)))))

(define (tree-vid ctx)
  (workspace-dock-vid (session-workspace (ctx-session ctx)) 'tree))

(define (tree-hook ctx _args)
  (define vid (tree-vid ctx))
  (if (and vid (tree-model ctx))
      (list (e-reload vid (tree->document (tree-model ctx)
                                          #:open? (lambda (p) (doc-open? ctx p)))))
      '()))

;;; ================= 命令 =================

(define (tree-entry-at-focus ctx)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (define t (tree-model ctx))
  (cond
    [(or (not vid) (not t)) #f]
    [else
     (define line (editor-view-point-line (session-editor s) vid))
     (define es (tree-entries t))
     (and (< line (length es)) (list-ref es line))]))

(define (tree-target-dir ctx)
  (define e (tree-entry-at-focus ctx))
  (define root (file-tree-root (tree-model ctx)))
  (cond [(not e) root]
        [(entry-dir? e) (entry-path e)]
        [else (let-values ([(base _n _d) (split-path (entry-path e))]) base)]))

(define (cmd-tree-activate ctx ev)
  (define e (tree-entry-at-focus ctx))
  (cond
    [(not e) '()]
    [(entry-dir? e) (file-tree-toggle! (tree-model ctx) (entry-path e)) '()]
    [else (list (e-file-open (entry-path e) 'replace #t))]))

(define (cmd-tree-new-file ctx ev)
  (define dir (tree-target-dir ctx))
  (list (e-prompt "new file: "
                  (λ (name)
                    (if (positive? (string-length name))
                        (begin (tree-create-file! dir name)
                               (file-tree-expand! (tree-model ctx) dir)
                               '())
                        '())))))

(define (cmd-tree-new-dir ctx ev)
  (define dir (tree-target-dir ctx))
  (list (e-prompt "new folder: "
                  (λ (name)
                    (if (positive? (string-length name))
                        (begin (tree-create-dir! dir name)
                               (file-tree-expand! (tree-model ctx) dir)
                               '())
                        '())))))

(define (cmd-tree-delete ctx ev)
  (define e (tree-entry-at-focus ctx))
  (cond
    [(not e) '()]
    [else
     (define p (entry-path e))
     (define (on-answer ans)
       (if (and (positive? (string-length ans))
                (char=? (char-downcase (string-ref ans 0)) #\y))
           (begin (tree-delete-path! p)
                  (list (e-close (doc-dids-under ctx p))))
           '()))
     (list (e-prompt (format "delete ~a? (y/n) " (entry-name e)) on-answer))]))

(define (cmd-tree-toggle ctx ev)
  (define s (ctx-session ctx))
  (define d (workspace-dock (session-workspace s) 'tree))
  (cond
    [(not d) '()]
    [(dock-visible? d) (list (e-dock-visible 'tree #f) e-focus-restore)]
    [else (list (e-dock-visible 'tree #t) (e-focus-push (dock-vid d)))]))

(define (register-tree! r)
  (for/fold ([r r])
            ([c (in-list (list (contrib 'init 'tree tree-init)
                               (contrib 'dock 'tree tree-spec)
                               (contrib 'hook 'tree (make-hook 'before-render tree-hook))
                               (contrib 'command 'tree-activate cmd-tree-activate)
                               (contrib 'command 'tree-new-file cmd-tree-new-file)
                               (contrib 'command 'tree-new-dir cmd-tree-new-dir)
                               (contrib 'command 'tree-delete cmd-tree-delete)
                               (contrib 'command 'tree-toggle cmd-tree-toggle)))])
    (reg-add r c)))

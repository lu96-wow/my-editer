#lang racket

;;; lab-rebuild/builtin/tree.rkt —— 文件树面板（功能包）。
;;;
;;; panel contribution：模型（展开集）+ 只读文档视图 + 键 + 每帧刷新。
;;; Enter 目录展开 / 文件打开；C-n 新建文件；C-l 新建目录；Backspace 删除。
;;; 树本身是一篇只读 document：core 的渲染 / 选区 / 滚动全套照用。

(require racket/file
         racket/path
         racket/string
         "../kernel/api.rkt"
         "prompt.rkt")

(provide register-tree!)

;;; ================= 模型 =================

(struct entry (path name dir? link? depth) #:transparent)

(struct file-tree (root expanded) #:mutable #:transparent)
;; expanded : hash 规范化路径 -> #t

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

(define (basename p)
  (path->string (or (file-name-from-path (path->complete-path p)) p)))

(define (tree-entries t)
  (define (node p depth)
    (define e (entry-of p depth))
    (if (and (entry-dir? e) (tree-expanded? t p))
        (cons e (append* (for/list ([c (in-list (sorted-children p))]) (node c (add1 depth)))))
        (list e)))
  (node (file-tree-root t) 0))

;;; ================= 文档 =================

(define (hidden-name? nm)
  (and (> (string-length nm) 0) (char=? (string-ref nm 0) #\.)))

(define (entry-face e open?)
  (cond [(and open? (not (entry-dir? e))) 'tree-open]
        [(hidden-name? (entry-name e)) 'tree-hidden]
        [(entry-link? e) 'tree-link]
        [(entry-dir? e) 'tree-dir]
        [else 'tree-file]))

(define (entry-line-text e indent)
  (string-append (make-string (* indent (entry-depth e)) #\space) (entry-name e)))

(define (tree->document t #:open? [open? (lambda (p) #f)])
  (define lines (for/list ([e (in-list (tree-entries t))])
                  (list (entry-line-text e 2) (entry-face e (open? (entry-path e))))))
  (define text (string-join (for/list ([l (in-list lines)]) (first l)) "\n"))
  (define doc (document-open text))
  (document-highlight-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length (first l)) (second l))))
  (document-readonly-fill-batch
   doc (for/list ([l (in-list lines)] [i (in-naturals)])
         (list i 0 i (string-length (first l)) #t)))
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

;;; ================= panel 装配 =================

(define (make-tree-panel root ed w h)
  (define-values (ed2 _did vid)
    (editor-add-document-view ed (document-open "") w h "*tree*"))
  (values ed2 vid (make-tree-model root)))

(define (refresh-tree ctx vid data)
  (define s (ctx-session ctx))
  (list (e-reload vid
                  (tree->document data #:open? (lambda (p) (path-table-open? (session-paths s) p))))))

(define tree-panel
  (panel-spec 'tree 10 make-tree-panel
              (list (kbd (key 'enter)     'tree-activate
                         (key 'n 'ctrl)   'tree-new-file
                         (key 'l 'ctrl)   'tree-new-dir
                         (key 'backspace) 'tree-delete
                         (key 'tab)       'toggle-left))
              refresh-tree))

;;; ================= 命令 =================

(define (tree-model ctx)
  (define s (ctx-session ctx))
  (define p (for/first ([p (in-list (session-panels s))] #:when (eq? (panel-name p) 'tree)) p))
  (and p (panel-data p)))

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
    [else (list (e-show (entry-path e) 'replace #t))]))

(define (cmd-tree-new-file ctx ev)
  (define dir (tree-target-dir ctx))
  (list (e-prompt "new file: " #t
                  (lambda (name)
                    (if (positive? (string-length name))
                        (begin (tree-create-file! dir name)
                               (file-tree-expand! (tree-model ctx) dir)
                               '())
                        '())))))

(define (cmd-tree-new-dir ctx ev)
  (define dir (tree-target-dir ctx))
  (list (e-prompt "new folder: " #t
                  (lambda (name)
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
     (define (on-answer yes?)
       (cond
         [(not yes?) '()]
         [else
          (tree-delete-path! p)
          (list (e-close (path-table-dids-under (session-paths (ctx-session ctx)) p)))]))
     (list (e-prompt (format "delete ~a? (y/n) " (entry-name e)) #f on-answer))]))

;;; ================= 注册 =================

(define (register-tree! r)
  (for/fold ([r r]) ([c (in-list (list (contrib 'panel 'tree 10 tree-panel)
                                       (contrib 'command 'tree-activate 0 cmd-tree-activate)
                                       (contrib 'command 'tree-new-file 0 cmd-tree-new-file)
                                       (contrib 'command 'tree-new-dir 0 cmd-tree-new-dir)
                                       (contrib 'command 'tree-delete 0 cmd-tree-delete)))] )
    (reg-add r c)))

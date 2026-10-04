#lang racket

(require "../core/editor.rkt"
         (except-in racket/list range)
         (only-in racket/path file-name-from-path)
         racket/file)

;;; lab-rebuild/tree.rkt —— 文件树（core 原生 document）
;;;
;;; 一行一个文件 / 文件夹，缩进区分层次，highlight 属性区分类型。整树只读。
;;; 成品的树就是一篇普通 document：core 的渲染 / 选区 / 滚动全套照用。

(provide (struct-out entry)
         file-tree? file-tree-root file-tree-expanded
         file-tree file-tree-toggle! file-tree-expand! file-tree-collapse! tree-expanded?
         tree-toggle! tree-expand! tree-collapse!
         tree-entries tree-entry-count
         tree-line->entry tree-line->path
         tree->lines tree->document tree-refresh!
         tree-create-file! tree-create-dir! tree-delete-path!
         default-entry-face
         tree-face-dir tree-face-file tree-face-link tree-face-hidden tree-face-open)

;;; ================= 模型 =================

(struct entry (path name dir? link? depth) #:transparent)

(struct file-tree% (root expanded) #:mutable #:transparent)
;; root     : 规范化绝对路径
;; expanded : 可变 hash path -> #t

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

;; 旧名兼容
(define tree-expand! file-tree-expand!)
(define tree-collapse! file-tree-collapse!)
(define tree-toggle! file-tree-toggle!)

;;; ---------- 扫描 ----------

(define (basename p)
  (define n (file-name-from-path p))
  (if n (path->string n) (path->string p)))

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

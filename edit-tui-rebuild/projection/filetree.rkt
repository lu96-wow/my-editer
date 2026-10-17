#lang racket

;;; projection/filetree.rkt —— 文件树面板的纯/IO 投影
;;;
;;; 行：
;;;   root   : 根目录完整路径（第一行）
;;;   dir    : 缩进 2 空格/层，蓝色
;;;   file   : 灰色；如果 workspace 里已打开同 path 的 document，则绿色
;;;
;;; 展开集合在插件切片 store['filetree]；根目录在 workspace.root。

(provide (struct-out filetree-line)
         filetree-lines
         filetree-line-at
         filetree-normalize-path
         filetree-dir?
         filetree-file?)

(require racket/path
         racket/list
         racket/string
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/filetree.rkt")

(struct filetree-line (path kind depth text face) #:transparent)
;; kind : 'root | 'dir | 'file

(define (filetree-normalize-path p)
  (path->string (simplify-path (path->complete-path p))))

(define (open-doc-paths state)
  (for/hash ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
             #:when (doc-meta-path dm))
    (values (filetree-normalize-path (doc-meta-path dm)) #t)))

(define (entry-kind path)
  (cond
    [(and (directory-exists? path) (not (link-exists? path))) 'dir]
    [(file-exists? path) 'file]
    [else #f]))

(define (dir-entry-paths path)
  (with-handlers ([exn:fail? (λ (_) '())])
    (define ps
      (for/list ([p (in-list (directory-list path))])
        (define f (build-path path p))
        (define k (entry-kind f))
        (and k (cons k f))))
    (sort (filter values ps)
          (λ (a b)
            (define ka (car a)) (define kb (car b))
            (cond [(and (eq? ka 'dir) (eq? kb 'file)) #t]
                  [(and (eq? ka 'file) (eq? kb 'dir)) #f]
                  [else (string<? (string-downcase (path->string (file-name-from-path (cdr a))))
                                  (string-downcase (path->string (file-name-from-path (cdr b)))))])))))

(define (indent depth) (make-string (* 2 depth) #\space))

(define (filetree-lines state)
  (define root (workspace-root (state-workspace state)))
  (define f (plugin-state state 'filetree (empty-filetree)))  ; 只管 expanded
  (define opened (open-doc-paths state))
  (cond
    [(or (not root) (string=? root "")) '()]
    [else
     (define root-norm (filetree-normalize-path root))
     (define (walk path depth)
       (define pn (filetree-normalize-path path))
       (define name (if (zero? depth)
                        root-norm
                        (path->string (file-name-from-path path))))
       (define face
         (cond [(zero? depth) 'filetree-root]
               [(directory-exists? path) 'filetree-dir]
               [(hash-has-key? opened pn) 'filetree-open]
               [else 'filetree-file]))
       (define line
         (filetree-line pn
                        (if (zero? depth) 'root 'dir)
                        depth
                        (string-append (indent depth) name)
                        face))
       (define children
         (cond
           [(and (directory-exists? path)
                 (not (link-exists? path))
                 (filetree-expanded? f pn))
            (append*
             (for/list ([e (in-list (dir-entry-paths path))])
               (define k (car e)) (define child (cdr e))
               (if (eq? k 'dir)
                   (walk child (add1 depth))
                   (let* ([cn (filetree-normalize-path child)]
                          [child-line
                           (filetree-line cn 'file (add1 depth)
                                          (string-append (indent (add1 depth))
                                                         (path->string (file-name-from-path child)))
                                          (if (hash-has-key? opened cn)
                                              'filetree-open
                                              'filetree-file))])
                     (list child-line)))))]
           [else '()]))
       (cons line children))
     (walk root 0)]))

(define (filetree-line-at state line)
  (define ls (filetree-lines state))
  (and (exact-nonnegative-integer? line)
       (< line (length ls))
       (list-ref ls line)))

(define (filetree-dir? l) (memq (filetree-line-kind l) '(root dir)))
(define (filetree-file? l) (eq? (filetree-line-kind l) 'file))

#lang racket

;;; layer  : plugins/filetree
;;; effect : 无（纯投影：state + 目录条目 -> 行）
;;;
;;; 文件树的行布局：
;;;   root  : 第一行是根目录完整路径（青色）
;;;   dir   : 缩进 2 空格/层（蓝色），展开时递归
;;;   file  : 灰色；若 workspace 里已打开同 path 的 document，则绿色
;;;
;;; 盘上有什么是**参数**（entry-lister），不是这里的 IO：
;;;   (filetree-lines state dir-entries)
;;; 生产用 scan.rkt 的 dir-entries，测试可以喂假目录。
;;;
;;; 状态来源：
;;;   展开集合  store['filetree].expanded
;;;   根目录    workspace.root
;;;   已打开集  由 workspace.docs 的 path 推出

(provide (struct-out filetree-line)
         filetree-lines
         filetree-line-at
         filetree-dir?
         filetree-file?)

(require racket/path
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "model.rkt"
         "scan.rkt")

(struct filetree-line (path kind depth text face) #:transparent)
;; path  : string（规范化后的绝对路径）
;; kind  : 'root | 'dir | 'file
;; depth : natural（缩进层数）
;; text  : string
;; face  : symbol

(define (open-doc-paths state)
  (for/hash ([(did dm) (in-hash (workspace-docs (state-workspace state)))]
             #:when (doc-meta-path dm))
    (values (filetree-normalize-path (doc-meta-path dm)) #t)))

(define (indent depth) (make-string (* 2 depth) #\space))

(define (entry-name path) (path->string (file-name-from-path path)))

;; entry-lister : string -> (listof (cons ('dir|'file) path))
(define (filetree-lines state entry-lister)
  (define root (workspace-root (state-workspace state)))
  (define expanded (filetree-expanded (plugin-state state 'filetree (empty-filetree))))
  (define opened (open-doc-paths state))
  (cond
    [(or (not root) (string=? root "")) '()]
    [else
     (define root-norm (filetree-normalize-path root))
     ;; 返回 (listof filetree-line)：目录递归展开成多行，文件是一行。
     (define (walk path depth kind)
       (define pn (filetree-normalize-path path))
       (define label (if (zero? depth) root-norm (entry-name path)))
       (define face
         (cond [(zero? depth)              'filetree-root]
               [(eq? kind 'dir)            'filetree-dir]
               [(hash-has-key? opened pn)  'filetree-open]
               [else                       'filetree-file]))
       (define line
         (filetree-line pn
                        (if (zero? depth) 'root kind)
                        depth
                        (string-append (indent depth) label)
                        face))
       (define children
         (if (and (eq? kind 'dir) (hash-has-key? expanded pn))
             (append* (for/list ([e (in-list (entry-lister pn))])
                        (walk (cdr e) (add1 depth) (car e))))
             '()))
       (cons line children))
     (walk root 0 'dir)]))

(define (filetree-line-at state line entry-lister)
  (define ls (filetree-lines state entry-lister))
  (and (exact-nonnegative-integer? line)
       (< line (length ls))
       (list-ref ls line)))

(define (filetree-dir? l) (memq (filetree-line-kind l) '(root dir)))
(define (filetree-file? l) (eq? (filetree-line-kind l) 'file))

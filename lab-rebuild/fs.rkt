#lang racket

;;; ============================================================================
;;; fs.rkt —— 文件系统
;;; ============================================================================
;;;
;;; 只有文件树文档认识它；别的文档不碰文件系统。
;;;
;;;   entry = 名字 ⊕ 绝对路径 ⊕ 是否目录
;;;   fs 操作：列目录 / 读文件 / 建文件 / 建目录 / 删（目录递归）
;;;
;;; 为什么单独一层：把「文件系统」和「树的状态/投影」分开，树只依赖这组函数。
;;; 路径一律用绝对 path；目录键统一去掉尾斜杠（canon-path），避免同目录两个键。

(require racket/file)

(provide entry entry? entry-name entry-path entry-dir? name-of canon-path
         fs-list fs-read fs-create fs-mkdir fs-delete)

;;; ---------- 条目 ----------

(struct entry (name path dir?) #:transparent)
;; name : string（显示名）
;; path : path（绝对路径）
;; dir? : bool

;; 显示名（目录带尾斜杠时 file-name-from-path 返回 #f，用 split-path 兜底）。
(define (name-of p)
  (define-values (_base name _dir?) (split-path p))
  (if name (path->string name) (path->string p)))

;; 去掉尾斜杠，统一目录键。
(define (canon-path p)
  (define s (path->string p))
  (define n (string-length s))
  (if (and (> n 1) (char=? (string-ref s (sub1 n)) #\/))
      (string->path (substring s 0 (sub1 n)))
      (string->path s)))

;;; ---------- 操作（对缺失路径要稳：不抛异常） ----------

(define (fs-list dir)
  (if (directory-exists? dir)
      (for/list ([p (in-list (directory-list dir #:build? #t))])
        (entry (name-of p) p (directory-exists? p)))
      '()))

;; 读文件；不是普通文件（不存在 / 是目录）→ #f。
(define (fs-read p)
  (if (and (file-exists? p) (not (directory-exists? p)))
      (file->string p)
      #f))

(define (fs-create p) (call-with-output-file p #:exists 'error void))
(define (fs-mkdir p) (make-directory p))

;; 删除；不存在就静默（健壮性）。仍拒绝删文件系统根。
(define (fs-delete p)
  (define-values (_base name _dir?) (split-path p))
  (when (not name) (error 'fs-delete "拒绝删除文件系统根目录: ~a" p))
  (cond
    [(directory-exists? p) (delete-directory/files p)]
    [(file-exists? p) (delete-file p)]
    [else (void)]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define d (make-temporary-file "rbfs-~a" 'directory))
  (define f (build-path d "a.txt"))
  (fs-create f)
  (check-true (file-exists? f))
  (check-equal? (fs-read f) "")
  (fs-mkdir (build-path d "sub"))
  (check-equal? (length (fs-list d)) 2)
  (check-true (for/or ([e (in-list (fs-list d))]) (and (entry-dir? e) (equal? (entry-name e) "sub"))))
  (fs-delete (build-path d "sub"))
  (check-equal? (length (fs-list d)) 1)
  (fs-delete f)
  (check-false (file-exists? f))
  (check-exn exn:fail? (lambda () (fs-delete (string->path "/"))))
  ;; 缺失路径：列目录 → '()；读 → #f；删 → 静默
  (check-equal? (fs-list (build-path d "nope")) '())
  (check-false (fs-read (build-path d "nope")))
  (fs-delete (build-path d "nope"))
  (delete-directory/files d)
  (displayln "lab-rebuild/fs.rkt: all tests passed"))

#lang racket

;;; fs.rkt —— 文件系统（树用它列目录 / 建 / 删 / 读）
;;;
;;; 只有树认识它；别的文档不碰。用真实文件系统，路径一律绝对 path。

(require racket/file)

(provide entry entry? entry-name entry-path entry-dir? name-of canon-path
         fs-list fs-read fs-create fs-mkdir fs-delete)

(struct entry (name path dir?) #:transparent)

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

(define (fs-list dir)
  (for/list ([p (in-list (directory-list dir #:build? #t))])
    (entry (name-of p) p (directory-exists? p))))

(define (fs-read p) (file->string p))
(define (fs-create p) (call-with-output-file p #:exists 'error void))
(define (fs-mkdir p) (make-directory p))
(define (fs-delete p)
  (define-values (_base name _dir?) (split-path p))
  (when (not name) (error 'fs-delete "拒绝删除文件系统根目录: ~a" p))
  (if (directory-exists? p) (delete-directory/files p) (delete-file p)))

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
  (delete-directory/files d)
  (displayln "lab-rebuild/fs.rkt: all tests passed"))

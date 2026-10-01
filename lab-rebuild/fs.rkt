#lang racket

;;; ============================================================================
;;; fs.rkt —— 文件系统（对缺失路径要稳）
;;; ============================================================================

(require racket/file)

(provide (struct-out entry)
         name-of canon
         entries read-text
         create-file! make-dir! delete!)

;; entry = 显示名 ⊕ 绝对路径 ⊕ 是否目录
(struct entry (name path dir?) #:transparent)

;; 显示名（目录带尾斜杠时 file-name-from-path 返回 #f，用 split-path 兜底）。
(define (name-of p)
  (define-values (_base name _dir?) (split-path p))
  (if name (path->string name) (path->string p)))

;; 去掉尾斜杠，统一目录键。
(define (canon p)
  (define s (path->string p))
  (define n (string-length s))
  (if (and (> n 1) (char=? (string-ref s (sub1 n)) #\/))
      (string->path (substring s 0 (sub1 n)))
      (string->path s)))

;; 列目录：文件夹在前，再按名字。缺失 → '()。
(define (entries dir)
  (if (directory-exists? dir)
      (sort (for/list ([p (in-list (directory-list dir #:build? #t))])
              (entry (name-of p) p (directory-exists? p)))
            (lambda (x y)
              (cond [(and (entry-dir? x) (not (entry-dir? y))) #t]
                    [(and (entry-dir? y) (not (entry-dir? x))) #f]
                    [else (string<? (entry-name x) (entry-name y))])))
      '()))

;; 读普通文件；不存在 / 是目录 → #f。
(define (read-text p)
  (if (and (file-exists? p) (not (directory-exists? p))) (file->string p) #f))

(define (create-file! p) (call-with-output-file p #:exists 'error void))
(define (make-dir! p) (make-directory p))

;; 删除；不存在就静默。仍拒绝删文件系统根。
(define (delete! p)
  (define-values (_base name _dir?) (split-path p))
  (when (not name) (error 'delete! "拒绝删除文件系统根: ~a" p))
  (cond
    [(directory-exists? p) (delete-directory/files p)]
    [(file-exists? p) (delete-file p)]
    [else (void)]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define d (make-temporary-file "rbfs-~a" 'directory))
  (define f (build-path d "a.txt"))
  (create-file! f)
  (check-true (file-exists? f))
  (check-equal? (read-text f) "")
  (make-dir! (build-path d "sub"))
  (check-equal? (map entry-name (entries d)) '("sub" "a.txt"))
  (check-true (entry-dir? (car (entries d))))
  (delete! (build-path d "sub"))
  (delete! f)
  (check-false (file-exists? f))
  (check-exn exn:fail? (lambda () (delete! (string->path "/"))))
  ;; 缺失路径稳
  (check-equal? (entries (build-path d "nope")) '())
  (check-false (read-text (build-path d "nope")))
  (delete! (build-path d "nope"))
  (delete-directory/files d)
  (displayln "lab-rebuild/fs.rkt: all tests passed"))

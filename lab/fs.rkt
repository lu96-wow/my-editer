#lang racket

(require racket/file)

;;; fs.rkt —— 文件系统抽象（读 + 写）
;;;
;;; 树不认识真实文件系统，只认识这个 fs 记录；于是「列目录 / 建目录 / 建文件 / 删」
;;; 都能在测试里换成内存实现，树组件保持可测。
;;;
;;;   entry = 名字 ⊕ 绝对路径 ⊕ 是否目录
;;;   fs    = list ⊕ mkdir ⊕ create ⊕ delete
;;;   fs-real / fs-memory

(provide
 (struct-out entry)
 (struct-out fs)
 name-of canon-path
 fs-real fs-memory)

;;; ---------- 条目 ----------

(struct entry (name path dir?) #:transparent)

;; 路径的显示名（目录带尾斜杠时 file-name-from-path 会返回 #f，用 split-path 兜底）。
(define (name-of p)
  (define-values (_base name _dir?) (split-path p))
  (if name (path->string name) (path->string p)))

;; 去掉尾斜杠，统一目录键（split-path 的 base 会带尾斜杠，root 不带）。
(define (canon-path p)
  (define s (path->string p))
  (define n (string-length s))
  (if (and (> n 1) (char=? (string-ref s (sub1 n)) #\/))
      (string->path (substring s 0 (sub1 n)))
      (string->path s)))

;;; ---------- fs ----------

(struct fs (list mkdir create delete) #:transparent)
;; list   : path → (listof entry)   目录下的条目（**绝对**路径），目录 / 文件都有
;; mkdir  : path → void             建目录
;; create : path → void             建空文件
;; delete : path → void             删文件 / 目录（目录递归）

;;; ---------- 真实文件系统 ----------

(define (fs-real)
  (fs (lambda (dir)
        (for/list ([p (in-list (directory-list dir #:build? #t))])
          (entry (name-of p) p (directory-exists? p))))
      (lambda (p) (make-directory p))
      (lambda (p) (call-with-output-file p #:exists 'error void))
      (lambda (p) (if (directory-exists? p)
                      (delete-directory/files p)
                      (delete-file p)))))

;;; ---------- 内存文件系统（测试 / 演示） ----------

;; init : (listof (cons path (or/c 'dir 'file)))
(define (fs-memory init)
  (define tbl (box (for/hash ([pr (in-list init)]) (values (string->path (car pr)) (cdr pr)))))
  (define (inside? root p)
    (and (not (equal? root p))
         (regexp-match? (regexp (string-append "^" (regexp-quote (path->string root)) "/"))
                        (path->string p))))
  (fs (lambda (dir)
        (define dd (canon-path dir))
        (for/list ([(p k) (in-hash (unbox tbl))]
                   #:when (equal? (canon-path (let-values ([(base _name _d) (split-path p)]) base)) dd))
          (entry (name-of p) p (eq? k 'dir))))
      (lambda (p) (set-box! tbl (hash-set (unbox tbl) p 'dir)))
      (lambda (p) (set-box! tbl (hash-set (unbox tbl) p 'file)))
      (lambda (p)
        (set-box! tbl (for/hash ([(q k) (in-hash (unbox tbl))]
                                 #:unless (or (equal? q p) (inside? p q)))
                       (values q k))))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define d (make-temporary-file "fsdir-~a" 'directory))
  (define f (build-path d "a.txt"))
  (define f2 (build-path d "b.txt"))

  (define F (fs-real))
  ((fs-create F) f)
  ((fs-create F) f2)
  ((fs-mkdir F) (build-path d "sub"))

  (define es ((fs-list F) d))
  (check-equal? (length es) 3)
  (check-true (for/and ([e (in-list es)]) (absolute-path? (entry-path e))))
  (check-true (for/or ([e (in-list es)]) (and (entry-dir? e) (equal? (entry-name e) "sub"))))
  (check-true (file-exists? f))

  ((fs-delete F) f)
  (check-false (file-exists? f))
  ((fs-delete F) (build-path d "sub"))
  (check-equal? (length ((fs-list F) d)) 1)

  ;; 内存实现
  (define M (fs-memory (list (cons "/r" 'dir) (cons "/r/a" 'dir) (cons "/r/a/x" 'file)
                             (cons "/r/b" 'file))))
  (check-equal? (length ((fs-list M) (string->path "/r"))) 2)
  ((fs-create M) (string->path "/r/c"))
  (check-equal? (length ((fs-list M) (string->path "/r"))) 3)
  ((fs-delete M) (string->path "/r/a"))                        ; 目录递归
  (check-equal? (sort (map entry-name ((fs-list M) (string->path "/r"))) string<?) '("b" "c"))

  (delete-directory/files d)
  (displayln "lab/fs.rkt: all tests passed"))

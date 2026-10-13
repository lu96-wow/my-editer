#lang racket

;;; edit2/fs.rkt —— 文件系统 I/O 边界（只是原语，不含策略）

(provide fs-read-dir fs-read-file fs-write-file fs-make-file fs-make-dir fs-delete
         fs-dir? fs-file? fs-exists?)

(require racket/file racket/path)

;; 目录项（排序：目录在前，再按名字）。
(define (fs-read-dir p)
  (define items
    (for/list ([c (in-list (directory-list p #:build? #t))])
      (cons c (directory-exists? c))))
  (sort items
        (lambda (a b)
          (define da (cdr a)) (define db (cdr b))
          (cond [(and da (not db)) #t] [(and db (not da)) #f]
                [else (string<? (path->string (file-name-from-path (car a)))
                                (path->string (file-name-from-path (car b))))]))))

(define (fs-dir? p) (and (directory-exists? p) #t))
(define (fs-file? p) (and (file-exists? p) (not (directory-exists? p)) #t))
(define (fs-exists? p) (or (file-exists? p) (directory-exists? p)))

;; 不存在 → ""（新文件）；目录 → 抛错（由上层记日志）。
(define (fs-read-file p)
  (cond [(fs-dir? p) (error 'fs-read-file "是一个目录: ~a" p)]
        [(fs-file? p) (file->string p)]
        [else ""]))

(define (fs-write-file p text)
  (call-with-output-file p #:exists 'truncate/replace
    (lambda (out) (display text out))))

;; 新建空文件 / 目录；已存在 → 抛错（由上层记日志）。
(define (fs-make-file p)
  (if (fs-exists? p)
      (error 'fs-make-file "已存在: ~a" p)
      (call-with-output-file p (lambda (out) (void)))))

(define (fs-make-dir p)
  (if (fs-exists? p)
      (error 'fs-make-dir "已存在: ~a" p)
      (make-directory p)))

;; 删除文件 / 目录（目录递归）。
(define (fs-delete p)
  (cond [(directory-exists? p) (delete-directory/files p)]
        [(file-exists? p) (delete-file p)]
        [else (error 'fs-delete "不存在: ~a" p)]))

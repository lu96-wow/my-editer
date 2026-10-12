#lang racket

;;; edit4/content/fs.rkt —— 文件系统原语（只做 IO，不含策略）

(provide fs-read-dir fs-read-file fs-write-file fs-file? fs-dir? fs-exists?)

(require racket/file racket/path)

;; 目录项（目录在前，再按名字）：(listof (cons path dir?))
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

(define (fs-read-file p)
  (cond [(fs-dir? p) (error 'fs-read-file "是一个目录: ~a" p)]
        [(fs-file? p) (file->string p)]
        [else ""]))

(define (fs-write-file p text)
  (call-with-output-file p #:exists 'truncate/replace
    (lambda (out) (display text out))))

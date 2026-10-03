#lang racket

;;; lab/fs.rkt —— 文件系统操作（唯一碰 racket/file 的地方之一）
;;;
;;; 只做最薄的一层：列目录（目录在前）、建文件/目录、删。上层（model/tree）用它。

(require racket/file racket/list racket/path)

(provide fs-exists? fs-dir? fs-list fs-create-file fs-create-dir fs-delete fs-name)

(define (fs-exists? p) (or (file-exists? p) (directory-exists? p)))
(define (fs-dir? p) (directory-exists? p))
(define (fs-name p)
  (define parts (explode-path p))
  (if (null? parts) (path->string p) (path->string (last parts))))

;; 目录在前、文件在后，各自按名字排序。
(define (fs-list dir)
  (define entries
    (for/list ([e (in-list (directory-list dir))])
      (build-path dir (file-name-from-path e))))
  (define dirs (sort (filter directory-exists? entries) string<? #:key path->string))
  (define files (sort (filter file-exists? entries) string<? #:key path->string))
  (append dirs files))

(define (fs-create-file p)
  (when (fs-exists? p) (error 'fs-create-file "已存在: ~a" p))
  (display-to-file "" p #:exists 'error)
  p)

(define (fs-create-dir p)
  (when (fs-exists? p) (error 'fs-create-dir "已存在: ~a" p))
  (make-directory p)
  p)

(define (fs-delete p)
  (cond [(directory-exists? p) (delete-directory/files p)]
        [(file-exists? p) (delete-file p)]
        [else (error 'fs-delete "不存在: ~a" p)]))

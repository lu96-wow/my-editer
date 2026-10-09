#lang racket

;;; edit/document/fs.rkt —— 文件系统 I/O 边界（资源侧）
;;;
;;; 所有裸文件系统操作集中在这里：列目录 / 读文本 / 写文本 / 建删。
;;; 上层（document 特征、tree 特征）只说「读这个路径 / 写这个路径」，
;;; 不直接碰 racket/file。tree-state 是纯状态机，靠注入的 read-dir 拿数据。

(require racket/file
         "../core/tree-state.rkt")

(provide fs-read-dir fs-read-file fs-write-file fs-path-kind
         fs-create-file fs-create-dir fs-delete)

(define (fs-read-dir p)
  (for/list ([c (in-list (directory-list p #:build? #t))])
    (direntry c (directory-exists? c) (link-exists? c))))

;; 'file | 'dir | #f
(define (fs-path-kind p)
  (cond [(directory-exists? p) 'dir]
        [(file-exists? p) 'file]
        [else #f]))

;; 读文本：不存在 → ""（新文件）；是目录 → 抛错（由上层记日志）。
(define (fs-read-file p)
  (case (fs-path-kind p)
    [(dir)  (error 'fs-read-file "是一个目录: ~a" p)]
    [(file) (file->string p)]
    [else   ""]))

(define (fs-write-file p text)
  (call-with-output-file p #:exists 'replace
    (lambda (out) (display text out))))

(define (fs-create-file p)
  (call-with-output-file p (lambda (out) (void)))
  p)

(define (fs-create-dir p)
  (make-directory p)
  p)

(define (fs-delete p)
  (cond [(directory-exists? p) (delete-directory/files p)]
        [else (delete-file p)]))

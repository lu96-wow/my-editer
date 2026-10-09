#lang racket

;;; edit/document/fs.rkt —— 文件系统 I/O 边界（资源侧）
;;;
;;; 只做「列目录 → direntry 列表」。tree-state 是纯状态机，靠注入的 read-dir
;;; 拿数据；错误处理先留空（后面再接结构化错误）。

(require racket/file
         racket/path
         "../core/tree-state.rkt")

(provide fs-read-dir)

(define (fs-read-dir p)
  (for/list ([c (in-list (directory-list p #:build? #t))])
    (direntry c (directory-exists? c) (link-exists? c))))

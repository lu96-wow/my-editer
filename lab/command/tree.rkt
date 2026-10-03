#lang racket

;;; lab/command/tree.rkt —— 树命令表（两棵树共用；按当前树 kind 分支）
;;;
;;; 焦点落在某个树视图上时，派发层用这张表（覆盖默认表）。
;;;   Enter     打开：文件树 目录=展开/折叠、文件=打开；文档树 文档/视图=聚焦
;;;   Backspace 关闭：文件树 目录=折叠、已打开文件=关文档；文档树 视图=关视图、文档=关文档
;;;   C-n       新建文件（输入行）
;;;   C-m       新建文件夹（输入行）
;;;   C-d       删除文件/文件夹（y/n 确认）

(require
 "base.rkt"
 "table.rkt"
 "../input.rkt"
 "../model/session.rkt"
 "../model/edit.rkt"
 "../model/tree.rkt")

(provide tree-table)

(define m0 (modifiers #f #f #f #f))
(define mC (modifiers #t #f #f #f))

;; f : session -> (values session effects)
(define (cmd name f)
  (make-command name (lambda (s ctx in) (f s))))

;; f : session -> session
(define (cmd/s name f)
  (make-command name (lambda (s ctx in) (values (f s) '()))))

(define tree-table
  (make-table
   (list
    (cons (binding 'enter m0)      (cmd   'open       tree-activate!))
    (cons (binding 'backspace m0)  (cmd/s 'close      tree-close!))
    (cons (binding 'tab m0)        (cmd/s 'switch     sidebar-switch!))   ; 切换文件树 / 文档树
    (cons (binding #\n mC)         (cmd/s 'new-file   (lambda (s) (tree-create! s 'file))))
    (cons (binding #\m mC)         (cmd/s 'new-dir    (lambda (s) (tree-create! s 'dir))))
    (cons (binding #\d mC)         (cmd/s 'delete     tree-delete!)))))

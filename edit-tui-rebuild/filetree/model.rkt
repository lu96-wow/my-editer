#lang racket

;;; edit-tui-rebuild/filetree/model.rkt —— 文件树面板状态（纯）

(provide (struct-out filetree-line)
         (struct-out filetree)
         empty-filetree
         make-filetree
         filetree-expanded?
         filetree-toggle-expand
         filetree-set-view
         filetree-set-line
         filetree-set-rows)

(struct filetree-line (path kind depth text face) #:transparent)
;; path : string（规范化绝对路径）
;; kind : 'root | 'dir | 'file
;; depth : natural
;; text : string
;; face : symbol | #f

(struct filetree
  (view        ; view-id | #f
   cursor      ; 选中行
   expanded    ; path -> #t
   rows)       ; (listof filetree-line)
  #:transparent)

(define (empty-filetree)
  (filetree #f 0 (hash) '()))

(define (make-filetree #:view [view #f]
                       #:line [line 0]
                       #:expanded [expanded (hash)]
                       #:rows [rows '()])
  (filetree view line expanded rows))

(define (filetree-expanded? f path)
  (hash-has-key? (filetree-expanded f) path))

(define (filetree-toggle-expand f path)
  (define h (filetree-expanded f))
  (struct-copy filetree f
               [expanded (if (hash-has-key? h path)
                             (hash-remove h path)
                             (hash-set h path #t))]))

(define (filetree-set-view f vid)
  (struct-copy filetree f [view vid]))

(define (filetree-set-line f line)
  (struct-copy filetree f [cursor line]))

(define (filetree-set-rows f rows)
  (struct-copy filetree f [rows rows]))

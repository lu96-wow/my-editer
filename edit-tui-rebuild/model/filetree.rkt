#lang racket

;;; model/filetree.rkt —— 文件树面板状态（纯数据）
;;;
;;; view     : filetree 面板自己的 view-id | #f
;;; root     : 根目录绝对路径（string）
;;; expanded : path -> #t，展开的目录

(provide (struct-out filetree)
         make-filetree
         empty-filetree
         filetree-expanded?
         filetree-toggle-expand
         filetree-set-view filetree-set-root filetree-set-width)

(struct filetree (view root expanded width) #:transparent)

(define (empty-filetree) (filetree #f "" (hash) #f))

(define (make-filetree #:view [view #f]
                       #:root [root ""]
                       #:expanded [expanded (hash)]
                       #:width [width #f])
  (filetree view root expanded width))

(define (filetree-expanded? f path)
  (hash-has-key? (filetree-expanded f) path))

(define (filetree-toggle-expand f path)
  (define h (filetree-expanded f))
  (struct-copy filetree f
               [expanded (if (hash-has-key? h path)
                             (hash-remove h path)
                             (hash-set h path #t))]))

(define (filetree-set-view f vid) (struct-copy filetree f [view vid]))
(define (filetree-set-root f root) (struct-copy filetree f [root root]))
(define (filetree-set-width f w) (struct-copy filetree f [width w]))

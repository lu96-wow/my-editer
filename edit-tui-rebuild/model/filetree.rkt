#lang racket

;;; model/filetree.rkt —— 文件树面板状态（插件切片，纯数据）
;;;
;;; 只放“这个面板自己的 UI 状态”：
;;;
;;;   view     : filetree 面板自己的 view-id | #f
;;;   expanded : path -> #t，展开的目录
;;;   width    : 隐藏前记录的内容宽度 | #f（C-b 恢复用）
;;;
;;; 根目录**不在**这里：它在 workspace.root（框架级），因为
;;;   · 状态栏要按它投影相对路径；
;;;   · 面板拔掉后工作区仍然有“从哪里看”的概念。
;;;
;;; 面板没安装时是 (empty-filetree)：所有字段都空，投影 / 同步都是 no-op。

(provide (struct-out filetree)
         make-filetree
         empty-filetree
         filetree-expanded?
         filetree-toggle-expand
         filetree-set-view filetree-set-width)

(struct filetree (view expanded width) #:transparent)

(define (empty-filetree) (filetree #f (hash) #f))

(define (make-filetree #:view [view #f]
                       #:expanded [expanded (hash)]
                       #:width [width #f])
  (filetree view expanded width))

(define (filetree-expanded? f path)
  (hash-has-key? (filetree-expanded f) path))

(define (filetree-toggle-expand f path)
  (define h (filetree-expanded f))
  (struct-copy filetree f
               [expanded (if (hash-has-key? h path)
                             (hash-remove h path)
                             (hash-set h path #t))]))

(define (filetree-set-view f vid) (struct-copy filetree f [view vid]))
(define (filetree-set-width f w) (struct-copy filetree f [width w]))

#lang racket

;;; model/filetree.rkt —— 文件树面板状态（插件切片，纯数据）
;;; layer  : plugins/filetree
;;; effect : 无（纯数据）

;;; 只放“这个面板自己的 UI 状态”：
;;;
;;;   view     : filetree 面板自己的 view-id | #f
;;;   expanded : path -> #t，展开的目录
;;;
;;; 显隐尺寸不在这里：toggle-region! 把隐藏时的尺寸写回 layout leaf 的 fixed dim。
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
         filetree-set-view)

(struct filetree (view expanded) #:transparent)

(define (empty-filetree) (filetree #f (hash)))

(define (make-filetree #:view [view #f]
                       #:expanded [expanded (hash)])
  (filetree view expanded))

(define (filetree-expanded? f path)
  (hash-has-key? (filetree-expanded f) path))

(define (filetree-toggle-expand f path)
  (define h (filetree-expanded f))
  (struct-copy filetree f
               [expanded (if (hash-has-key? h path)
                             (hash-remove h path)
                             (hash-set h path #t))]))

(define (filetree-set-view f vid) (struct-copy filetree f [view vid]))

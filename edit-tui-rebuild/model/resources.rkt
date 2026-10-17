#lang racket

;;; model/resources.rkt —— 全局资源管理状态（纯数据）
;;;
;;; confirm  : save-confirm 流程 | #f
;;; collapsed: doc-id -> #t        资源列表里折叠的 document
;;; pending  : #f | view-id        等待“选中替换到目标 panel”的 view
;;; view     : #f | view-id        资源列表面板自己的 view

(provide (struct-out save-confirm)
         (struct-out resources)
         make-save-confirm
         make-resource-state
         resources-empty
         resources-set-confirm
         resources-collapsed? resources-toggle-collapse
         resources-pending resources-set-pending
         resources-view resources-set-view)

(struct save-confirm (docs index action) #:transparent)

(define (make-save-confirm docs action [index 0])
  (save-confirm docs index action))

(struct resources (confirm collapsed pending view) #:transparent)

(define (resources-empty) (resources #f (hash) #f #f))

(define (make-resource-state #:confirm [confirm #f]
                             #:collapsed [collapsed (hash)]
                             #:pending [pending #f]
                             #:view [view #f])
  (resources confirm collapsed pending view))

(define (resources-set-confirm r c) (struct-copy resources r [confirm c]))

(define (resources-collapsed? r did)
  (hash-has-key? (resources-collapsed r) did))
(define (resources-toggle-collapse r did)
  (define h (resources-collapsed r))
  (struct-copy resources r
               [collapsed (if (hash-has-key? h did)
                              (hash-remove h did)
                              (hash-set h did #t))]))

(define (resources-set-pending r vid)
  (struct-copy resources r [pending vid]))
(define (resources-set-view r vid)
  (struct-copy resources r [view vid]))

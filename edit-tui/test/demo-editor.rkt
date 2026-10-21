#lang racket

;;; 测试辅助：给 demo 状态打开一个 editor 文档并挂到 editor panel。
(require "../main.rkt"
         "../config/keymap/buffer.rkt")

(provide open-editor-into-demo)

(define (open-editor-into-demo state engine text
                               #:name [name "editor"]
                               #:path [path #f])
  (define-values (store actions)
    (resource-open (app-state-resources state)
                   #:name name
                   #:path path
                   #:text text
                   #:key-table (buffer-key-table path text)))
  (define s1 (run-actions (struct-copy app-state state [resources store])
                          engine actions))
  (define rid (resource-id (car (resource-list store))))
  (define vid (first (resource-view-ids store rid)))
  (define-values (layout* ok?) (layout-panel-add-view (app-state-layout s1) 'editor vid))
  (unless ok? (error 'open-editor-into-demo "editor panel missing"))
  (app-state-set-focus-panel
   (struct-copy app-state s1 [layout layout*])
   'editor))

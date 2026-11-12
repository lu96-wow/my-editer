#lang racket

;;; edit-tui/host/app-layout.rkt —— app 初始布局装配
;;;
;;; 这是 host assembly：知道 editor / status / sidebar / docs 这些具体 kind。
;;; editor/layout.rkt 只保留通用布局操作，不再知道这些具体面板。

(require "../core/layout/api.rkt"
         (prefix-in p: "../core/panel/api.rkt")
         "../config/layout/default.rkt")

(provide make-editor-layout
         default-layout-config)

(define (make-editor-layout #:editor-view editor-vid
                            #:editor-panel-id [editor-pid 'editor]
                            #:status-view [status-vid #f]
                            #:status-views [status-views
                                           (if status-vid (list status-vid) '())]
                            #:status-panel-id [status-pid 'status]
                            #:sidebar-view [sidebar-vid #f]
                            #:sidebar-views [sidebar-views
                                            (if sidebar-vid (list sidebar-vid) '())]
                            #:sidebar-panel-id [sidebar-pid 'filetree]
                            #:sidebar-w [sidebar-w 24]
                            #:docs-view [docs-vid #f]
                            #:docs-panel-id [docs-pid 'docs]
                            #:docs-ratio [docs-ratio 20/23])
  (define editor-panel
    (p:make-panel editor-pid 'editor
                  #:views (list editor-vid)
                  #:active editor-vid
                  #:borders '(up down left right)))
  (define l0
    (make-layout #:root (make-leaf editor-pid)
                 #:panels (hash editor-pid editor-panel)
                 #:focus editor-pid))
  (define l1
    (cond
      [(null? sidebar-views) l0]
      [else
       (define sidebar-panel
         (p:make-panel sidebar-pid 'sidebar
                       #:views sidebar-views
                       #:active (car sidebar-views)
                       #:fixed-w sidebar-w
                       #:borders '(right)))
       (define-values (l* ok?)
         (layout-panel-attach l0 editor-pid 'left sidebar-panel))
       (unless ok?
         (error 'make-editor-layout "sidebar attach failed"))
       l*]))
  (define l2
    (cond
      [(null? status-views) l1]
      [else
       (define status-panel
         (p:make-panel status-pid 'status
                       #:views status-views
                       #:active (car status-views)
                       #:fixed-h 1))
       (define-values (l* ok?)
         (layout-panel-attach l1 editor-pid 'down status-panel))
       (unless ok?
         (error 'make-editor-layout "status attach failed"))
       l*]))
  (cond
    [(not docs-vid) l2]
    [else
     (define docs-panel
       (p:make-panel docs-pid 'docs
                     #:views (list docs-vid)
                     #:active docs-vid
                     #:borders '(up down left right)))
     (define-values (l* ok?)
       (layout-panel-attach l2 editor-pid 'down docs-panel #:ratio docs-ratio))
     (unless ok?
       (error 'make-editor-layout "docs attach failed"))
     l*]))

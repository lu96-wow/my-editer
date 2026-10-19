#lang racket

;;; 用新的 split 布局渲染 80x24：
;;;   filetree | editor(empty)
;;;            | state
;;;
;;; 布局状态只存 split 关系 + panel 资源；rect 由 layout-solve 算。

(require "../../core/editor.rkt"
         (prefix-in p: "../model/panel.rkt")
         (prefix-in l: "../model/layout.rkt")
         "../projection/geometry.rkt")

(define W 80)
(define H 24)
(define sidebar-w 30)

;; ---------- core view ----------
(define ft-buffer (make-buffer "workspace\n  src\n  main.rkt"))
(define ft-view (buffer-add-view! ft-buffer 29 H))

(define state-buffer (make-buffer "state focus=editor docs=1 pending=- msg=ready"))
(define state-view (buffer-add-view! state-buffer (- W sidebar-w) 1))

;; ---------- panel 资源 ----------
(define ft-panel
  (p:make-panel 'filetree 'sidebar
                #:views (list ft-view)
                #:active ft-view
                #:fixed-w sidebar-w
                #:borders '(right)))

(define state-panel
  (p:make-panel 'state 'status
                #:views (list state-view)
                #:active state-view
                #:fixed-h 1))

(define editor-panel (p:make-empty-editor-panel 'editor))

;; ---------- split 树 ----------
(define l0 (l:make-layout #:root (l:leaf 'editor)
                          #:panels (hash 'editor editor-panel)
                          #:focus 'editor))
(define-values (l1 ok1) (l:layout-panel-attach l0 'editor 'left ft-panel))
(define-values (l2 ok2) (l:layout-panel-attach l1 'editor 'down state-panel))
(unless (and ok1 ok2) (error 'demo "layout attach failed"))

;; ---------- 渲染 ----------
(define panels (layout->render-panels l2 (rect 0 0 W H)))
(panels-sync! panels)
(displayln (screen->string (render-display panels #f W H)))

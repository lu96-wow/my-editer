#lang racket

;;; 用统一 API 面渲染 80x24：
;;;   filetree | editor(empty)
;;;            | state
;;;
;;; 演示：layout 状态 + panel 资源 + layout-solve + 渲染 API。

(require (only-in "../../core/editor.rkt"
                  make-buffer buffer-add-view!)
         "../main.rkt")

(define W 80)
(define H 24)
(define sidebar-w 30)

;; ---------- core view（初始尺寸故意很小，渲染前由 layout-sync! 修正） ----------
(define ft-buffer (make-buffer "workspace\n  src\n  main.rkt"))
(define ft-view (buffer-add-view! ft-buffer 1 1))

(define state-buffer (make-buffer "state focus=editor docs=1 pending=- msg=ready"))
(define state-view (buffer-add-view! state-buffer 1 1))

;; ---------- panel 资源 ----------
(define ft-panel
  (make-panel 'filetree 'sidebar
              #:views (list ft-view)
              #:active ft-view
              #:fixed-w sidebar-w
              #:borders '(right)))

(define state-panel
  (make-panel 'state 'status
              #:views (list state-view)
              #:active state-view
              #:fixed-h 1))

(define editor-panel (make-empty-editor-panel 'editor))

;; ---------- split 树 ----------
(define l0 (make-layout #:root (make-leaf 'editor)
                        #:panels (hash 'editor editor-panel)
                        #:focus 'editor))
(define-values (l1 ok1) (layout-panel-attach l0 'editor 'left ft-panel))
(define-values (l2 ok2) (layout-panel-attach l1 'editor 'down state-panel))
(unless (and ok1 ok2) (error 'demo "layout attach failed"))

;; ---------- 渲染 ----------
(define-values (_cache bytes)
  (render-layout l2 (rect 0 0 W H) #:focus-panel 'editor))
(displayln (bytes->string/utf-8 bytes))

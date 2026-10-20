#lang racket

;;; 用统一 API 面渲染 80x24：
;;;   filetree | editor(empty)
;;;            | state
;;;
;;; 演示：engine（buffer/view）+ panel 资源 + layout-solve + 渲染 API。
;;; 只 require main.rkt —— 不直接碰 core。

(require "../main.rkt")

(define W 80)
(define H 24)
(define sidebar-w 30)

;; ---------- skeleton engine：buffer / view ----------
(define engine (make-engine))
(void (engine-create-buffer! engine 1 "*filetree*" "workspace\n  src\n  main.rkt"))
(void (engine-create-view! engine 1 1))
(void (engine-create-buffer! engine 2 "*state*"
                              "state focus=editor docs=1 pending=- msg=ready"))
(void (engine-create-view! engine 2 2))

;; ---------- panel 资源（view 以 id 引用） ----------
(define ft-panel
  (make-panel 'filetree 'sidebar
              #:views '(1)
              #:active 1
              #:fixed-w sidebar-w
              #:borders '(right)))

(define state-panel
  (make-panel 'state 'status
              #:views '(2)
              #:active 2
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
  (render-layout l2 (rect 0 0 W H)
                 #:focus-panel 'editor
                 #:view-object (λ (vid) (engine-view-object engine vid))))
(displayln (bytes->string/utf-8 bytes))

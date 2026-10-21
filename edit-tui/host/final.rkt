#lang racket

;;; edit-tui-rebuild/host/final.rkt —— 最终编辑器装配（第一版）
;;;
;;; 组成：
;;;   editor / docs / status（复用 completion-docs 运行时）
;;;   + filetree / resources 共用 sidebar
;;;   + input 接在 status panel
;;;
;;; 启动不打开默认 buffer：layout 的 editor 是空 panel，用户从 filetree 打开文件。
;;; 后续会把 completion/docs 抽成正式插件，再把这里改成纯 install 列表。

(require racket/path
         "../config/keymap/default.rkt"
         "../config/layout/default.rkt"
         "../config/theme/default.rkt"
         "../main.rkt"
         "../demo/completion-docs.rkt")

(provide final-state final-engine run-final!)

(define final-engine demo-engine)

;;; ════════════════ 核心 view：filetree / resources / input ════════════════

(define filetree-vid 10)
(define resources-vid 11)

;; completion-docs demo 固定使用这些 id。
(define status-vid 20)
(define docs-vid 30)
(define input-vid 21)

;; 边界：最终编辑器启动不保留 demo 的默认 editor buffer。
(engine-remove-view! final-engine 1)
(engine-remove-doc! final-engine 1)

(define (create-plain-view! vid name)
  (void (engine-create-buffer! final-engine vid name ""))
  (void (engine-create-view! final-engine vid vid)))

(create-plain-view! filetree-vid "*filetree*")
(create-plain-view! resources-vid "*resources*")
(create-plain-view! input-vid "*input*")

;;; ════════════════ 初始 state：空资源 + 已有 docs/status/completion view ════════════════

(define base-state
  (struct-copy app-state demo-state
               [resources resource-store-empty]
               [layout #f]
               [store (hash-set (app-state-store demo-state)
                                'demo/docs
                                empty-docs)]))

(define state1
  (filetree-install-state base-state
                          filetree-vid
                          (path->complete-path (current-directory))
                          #:panel-stack filetree-panel-stack))
(define state2
  (resource-panel-install-state state1 resources-vid
                                #:panel-stack resource-panel-stack))
(define state3
  (input-install-state state2 'status status-vid input-vid))

;;; ════════════════ 布局：空 editor + docs + status/input + sidebar ════════════════

(define empty-editor-panel
  (make-panel 'editor 'editor
              #:borders '(up down left right)))

(define sidebar-panel
  (make-panel 'filetree 'sidebar
              #:views (list filetree-vid resources-vid)
              #:active filetree-vid
              #:borders '(right)))

(define docs-panel
  (make-panel 'docs 'docs
              #:views (list docs-vid)
              #:active docs-vid
              #:fixed-h 1
              #:borders '(up down left right)))

(define status-panel
  (make-panel 'status 'status
              #:views (list status-vid input-vid)
              #:active status-vid
              #:fixed-h 1))

(define layout0
  (make-layout #:root (make-leaf 'editor)
               #:panels (hash 'editor empty-editor-panel)
               #:focus 'editor))

;; 先挂 sidebar，再挂 status，最后把 docs 插到 editor 和 status 之间。
;; 顺序很重要：docs / status 都固定一行时，后挂的固定 panel 不能吃掉剩余高度。
(define-values (layout1 sidebar-ok?)
  (layout-panel-attach layout0 'editor 'left sidebar-panel #:ratio 3/8))
(define-values (layout2 status-ok?)
  (layout-panel-attach layout1 'editor 'down status-panel))
(define-values (layout3 docs-ok?)
  (layout-panel-attach layout2 'editor 'down docs-panel))

(unless (and docs-ok? status-ok? sidebar-ok?)
  (error 'final "layout attach failed"))

(define final-state
  (struct-copy app-state state3 [layout layout3]))

;;; ════════════════ 入口 ════════════════

(define (run-final!)
  (run-demo final-state final-engine))

(module+ main
  (void (run-final!)))

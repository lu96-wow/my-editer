#lang racket

;;; edit-tui-rebuild/host/final.rkt —— 最终编辑器装配（第一版）
;;;
;;; 组成：
;;;   editor / docs / status（来自 completion-docs）
;;;   + filetree / resources 共用 sidebar
;;;   + input 接在 status panel
;;;
;;; 这一版直接复用 demo/completion-docs 的 completion/docs/color 运行时；
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
(define input-vid 21)

(define (create-plain-view! vid name)
  (void (engine-create-buffer! final-engine vid name ""))
  (void (engine-create-view! final-engine vid vid)))

(create-plain-view! filetree-vid "*filetree*")
(create-plain-view! resources-vid "*resources*")
(create-plain-view! input-vid "*input*")

;;; ════════════════ 安装：filetree / resources / input ════════════════

(define state1
  (filetree-install-state demo-state
                          filetree-vid
                          (path->complete-path (current-directory))
                          #:panel-stack filetree-panel-stack))
(define state2
  (resource-panel-install-state state1 resources-vid
                                #:panel-stack resource-panel-stack))
(define state3
  (input-install-state state2 'status 20 input-vid))

;;; ════════════════ 布局：sidebar + status/input ════════════════

(define sidebar-panel
  (make-panel 'filetree 'sidebar
              #:views (list filetree-vid resources-vid)
              #:active filetree-vid
              #:borders '(right)))

(define layout0 (app-state-layout state3))

;; status panel 同时挂 status / input，两边切换沿用已有规则。
(define-values (layout1 _status-ok?)
  (layout-panel-update layout0 'status
                       (λ (p)
                         (panel-set-views p (list 20 input-vid) 20))))

(define-values (layout2 sidebar-ok?)
  (layout-panel-attach layout1 'editor 'left sidebar-panel #:ratio 3/8))

(unless sidebar-ok?
  (error 'final "attach sidebar failed"))

(define final-state
  (struct-copy app-state state3 [layout layout2]))

;;; ════════════════ 入口 ════════════════

(define (run-final!)
  (run-demo final-state final-engine))

(module+ main
  (void (run-final!)))

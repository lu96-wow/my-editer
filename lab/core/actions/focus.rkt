#lang racket

(require "../../base/layout/main.rkt"
         "../state.rkt"
         "../panes.rkt"
         "core.rkt")

;;; lab-rebuild/core/actions/focus.rkt —— 焦点移动（几何）与左栏开关

(provide app-move-focus! app-toggle-sidebar! app-toggle-left!)

;; 按几何邻居移焦点（前缀键方向用）。
(define (app-move-focus! a dir)
  (define vid (pane-dir (app-focus-panes a) (app-focus a) dir))
  (when vid (set-app-focus! a vid)))

;; 焦点是否落在左栏（tree / bufs）。
(define (sidebar-focus? a)
  (memv (app-focus a) (list (panes-tree (app-panes a)) (panes-bufs (app-panes a)))))

;; Ctrl+B：开 / 关左侧视图。
;;   关：若焦点在左栏 → 移到当前编辑窗格；**没有编辑窗格就置空**（不放到底部槽）。
;;   开：聚焦左栏（打开就是为了用它）。
(define (app-toggle-sidebar! a)
  (define show? (not (app-sidebar? a)))
  (app-sidebar-set! a show?)
  (cond
    [show? (set-app-focus! a (app-left-vid a))]
    [(sidebar-focus? a) (set-app-focus! a (app-edit-active a))]
    [else (void)]))

;; 左侧面板：文件树 ↔ 文档列表（若左栏被关掉，先打开）。
(define (app-toggle-left! a)
  (unless (app-sidebar? a) (app-sidebar-set! a #t))
  (app-left-set! a (if (eq? (app-left a) 'tree) 'bufs 'tree))
  (app-bufs-refresh! a)
  (set-app-focus! a (app-left-vid a)))

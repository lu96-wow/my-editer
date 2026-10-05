#lang racket

(require "../../base/layout/main.rkt"
         "../state.rkt"
         "../panes.rkt"
         "core.rkt")

;;; lab-rebuild/app/actions/focus.rkt —— 焦点移动（几何）与左右栏切换

(provide app-move-focus! app-toggle-focus! app-toggle-left!)

;; 按几何邻居移焦点（前缀键方向用）。
(define (app-move-focus! a dir)
  (define vid (pane-dir (app-focus-panes a) (app-focus a) dir))
  (when vid (set-app-focus! a vid)))

;; 左栏（tree / bufs）↔ 当前编辑窗格。
(define (app-toggle-focus! a)
  (define p (app-panes a))
  (define ev (app-edit-active a))
  (when ev
    (set-app-focus! a (if (memv (app-focus a) (list (panes-tree p) (panes-bufs p)))
                          ev
                          (app-left-vid a)))))

;; 左侧面板：文件树 ↔ 文档列表。
(define (app-toggle-left! a)
  (app-left-set! a (if (eq? (app-left a) 'tree) 'bufs 'tree))
  (app-bufs-refresh! a)
  (set-app-focus! a (app-left-vid a)))

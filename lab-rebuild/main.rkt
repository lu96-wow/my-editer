#lang racket

(require "backend/tui.rkt")

;;; lab-rebuild/main.rkt —— TUI 入口
;;;
;;;   racket lab-rebuild/main.rkt [文件 / 根目录]
;;;
;;; 有参数且是文件 → 打开它；否则当作根目录启动空编辑器。

(module+ main
  (define args (current-command-line-arguments))
  (define arg (and (positive? (vector-length args)) (vector-ref args 0)))
  (cond
    [(not arg) (app-run (current-directory))]
    [(file-exists? arg) (app-run (current-directory) (path->complete-path arg))]
    [else (app-run arg)]))

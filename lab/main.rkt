#lang racket

(require "backend/tui.rkt")

;;; lab/main.rkt —— TUI 入口
;;;
;;;   racket lab/main.rkt [根目录]

(module+ main
  (define args (current-command-line-arguments))
  (define root (if (positive? (vector-length args))
                   (vector-ref args 0)
                   (current-directory)))
  (app-run root))

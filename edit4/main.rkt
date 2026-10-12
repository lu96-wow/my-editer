#lang racket

;;; edit4/main.rkt —— 入口
;;;
;;;   racket edit4/main.rkt [file]
;;;
;;; boot 出一个初始 World，交给 tui 后端运行。

(provide main)

(require racket/file
         "app.rkt"
         "backend/tui.rkt")

(define (main)
  (define args (current-command-line-arguments))
  (define path (and (positive? (vector-length args)) (vector-ref args 0)))
  (define text (if (and path (file-exists? path)) (file->string path) ""))
  (define name (if path path "*scratch*"))
  (define w (boot #:text text #:name name #:path (and path (path->complete-path path))))
  (run-tui (app-commands) (app-scopes) (app-keymap) w))

(module+ main (main))

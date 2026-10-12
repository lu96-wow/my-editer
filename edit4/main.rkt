#lang racket

;;; edit4/main.rkt —— 入口
;;;
;;;   racket edit4/main.rkt [file]
;;;
;;; 装配出 Environment，boot 出初始 World，交给 tui 后端运行。

(provide main)

(require racket/file
         "app.rkt"
         "boot.rkt"
         "backend/tui.rkt")

(define (main)
  (define args (current-command-line-arguments))
  (define path (and (positive? (vector-length args)) (vector-ref args 0)))
  (define text (if (and path (file-exists? path)) (file->string path) ""))
  ;; 无文件参数 → 不建初始文档（从文件树打开）。
  (define w (boot #:text text #:name path #:path (and path (path->complete-path path))))
  (run-tui (app-environment) w))

(module+ main (main))

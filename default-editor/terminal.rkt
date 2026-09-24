#lang racket

;;; default-editor/terminal.rkt —— 默认终端后端：shell 与通用前端的接线
;;;
;;; 通用部分（screen → ANSI、增量重绘、事件循环、输入翻译、默认样式）全在 ui/tui.rkt；
;;; 这里只剩「把 shell 的三个纯操作接到 run-tui」，是 ui 的第一个实例。
;;;
;;;   project : shell -> screen        = shell->screen
;;;   handle  : shell event -> (values shell quit?) = shell-handle
;;;   resize  : shell rows cols -> shell            = shell-resize

(require "shell.rkt"
         "../ui/tui.rkt")

(provide run-default-editor
         ;; 兼容旧入口：整屏 → 字节（转发 ui/tui）
         screen->bytes)

(define (run-default-editor [path #f] #:root [root (current-directory)])
  (run-tui (shell-open path 24 80 #:root root)
           #:project shell->screen
           #:handle  shell-handle
           #:resize  (lambda (s rows cols) (shell-resize s rows cols))))

(module+ test
  (require rackunit racket/path racket/file)
  (define dir (make-temporary-file "edterm~a" 'directory))
  (call-with-output-file (build-path dir "a.txt") #:exists 'replace (lambda (o) (display "hi" o)))
  (define s (shell-open #f 8 40 #:root dir))
  (define b (screen->bytes (shell->screen s)))
  (check-true (bytes? b))
  (check-true (> (bytes-length b) 0))
  (check-true (regexp-match? #rx"scratch" (bytes->string/utf-8 b)))   ; 状态栏在主文档名
  (delete-directory/files dir)
  (displayln "terminal.rkt: all tests passed"))

(module+ main
  (define args (current-command-line-arguments))
  (run-default-editor (and (> (vector-length args) 0) (vector-ref args 0))))

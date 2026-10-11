#lang racket

;;; edit3/main.rkt —— 入口
;;;
;;;   racket edit3/main.rkt [file]
;;;
;;; 核心（edit3）不认识终端；这里组装 boot 出的 State 并交给 tui 后端。

(provide main)

(require racket/file
         "core/step.rkt"
         "core/backend/tui.rkt")

(define (main)
  (define args (current-command-line-arguments))
  (define path (and (positive? (vector-length args)) (vector-ref args 0)))
  (define text (if (and path (file-exists? path)) (file->string path) ""))
  ;; 无文件参数 → 不建初始文档：编辑区留空窗口，从文件树打开。
  (define st0 (boot 80 24 #:text text #:name path))
  (define st (if path (set-focused-path! st0 path) st0))
  (run-tui st))

(module+ main (main))

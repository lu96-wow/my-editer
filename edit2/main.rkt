#lang racket

;;; edit2/main.rkt —— 入口
;;;
;;;   racket edit2/main.rkt [file]
;;;
;;; 核心（edit2）不认识终端；这里组装 boot 出的 State 并交给 tui 后端。

(require racket/file
         "core/state.rkt"
         "core/step.rkt"
         "core/backend/tui.rkt")

(provide main)

(define (main)
  (define args (current-command-line-arguments))
  (define path (and (positive? (vector-length args)) (vector-ref args 0)))
  (define text (if (and path (file-exists? path)) (file->string path) ""))
  (define st0 (boot text (or path "*scratch*") 80 24))
  (define st (if path (set-focused-path! st0 path) st0))
  (run-tui st))

(module+ main (main))

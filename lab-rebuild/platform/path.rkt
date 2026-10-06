#lang racket

(require racket/path)

;;; lab-rebuild/base/path.rkt —— 路径小工具（ui / app 共用，无上层依赖）

(provide basename)

;; 路径最后一段的名字；根等无名路径 → 整串。
(define (basename p)
  (define np (path->complete-path p))
  (path->string (or (file-name-from-path np) np)))

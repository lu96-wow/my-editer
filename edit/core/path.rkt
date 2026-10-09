#lang racket

;;; edit/core/path.rkt —— 路径工具（纯）
;;;
;;; 各处（file-map / tree-state / document / feature/tree）原本各带一份
;;; normalize；统一到这里。

(require racket/path)

(provide normalize path-under? path=?)

;; 规范化：补成绝对路径 + 化简（去 . / .. / 尾斜杠）。
(define (normalize p) (simplify-path (path->complete-path p)))

;; p 是否在 root 之下（含相等）。
(define (path-under? root p)
  (define r (explode-path (normalize root)))
  (define q (explode-path (normalize p)))
  (and (>= (length q) (length r)) (equal? r (take q (length r)))))

;; 两个路径规范化后是否相同。
(define (path=? a b) (equal? (normalize a) (normalize b)))

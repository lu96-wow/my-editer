#lang racket

;;; ============================================================================
;;; theme.rkt —— 主题：face → 真彩色（纯数据）
;;; ============================================================================
;;;
;;; core 的 face 是不透明值；只有这里知道它们对应什么颜色。后端把 RGB 变成
;;; 自己的表现（tui 用真彩色转义，gui 用 make-color）。
;;;
;;;   face-colors : face → (values fg bg)；fg/bg = (list r g b) | #f

(provide theme face-colors)

(define theme
  (hash 'tree-root   '((240 150 60) . #f)    ; 根目录（橙，标题）
        'tree-dir    '((120 180 240) . #f)   ; 文件夹
        'tree-file   '((200 200 200) . #f)   ; 文件（未打开）
        'tree-open   '((150 210 150) . #f)   ; 已打开的文件
        'tree-prompt '((229 192 123) . #f))) ; 输入行

;; 未知 face → 浅灰。
(define (face-colors face)
  (define p (hash-ref theme face #f))
  (if p (values (car p) (cdr p)) (values '(205 205 205) #f)))

(module+ test
  (require rackunit)
  (define-values (fg bg) (face-colors 'tree-dir))
  (check-equal? fg '(120 180 240))
  (check-false bg)
  (define-values (rfg _rbg) (face-colors 'tree-root))
  (check-equal? rfg '(240 150 60))
  (define-values (ufg _ubg) (face-colors 'nope))
  (check-equal? ufg '(205 205 205))
  (displayln "lab-rebuild/theme.rkt: all tests passed"))

#lang racket

;;; ============================================================================
;;; theme.rkt —— 主题：face → 真彩色（纯数据）
;;; ============================================================================
;;;
;;; core 的 face 是不透明值（'tree-dir、'tree-file、'status …）；只有这里知道
;;; 它们对应什么颜色。后端把 RGB 变成终端的真彩色（tui 用 format-rgb-*-base）。
;;;
;;; 放成数据：
;;;   theme : hash（face → (fg . bg)）
;;;   fg / bg : (list r g b) | #f（#f = 用终端默认）
;;;
;;; 加一种 face 的配色，只改这张表。

(provide theme face-colors)

(define theme
  (hash 'tree-root   '((240 150 60) . #f)    ; 根目录（橙，标题）
        'tree-dir    '((120 180 240) . #f)   ; 文件夹
        'tree-file   '((200 200 200) . #f)   ; 文件（未打开）
        'tree-open   '((150 210 150) . #f)   ; 已打开的文件
        'tree-prompt '((229 192 123) . #f)   ; 输入行
        'tree-view        '((190 190 205) . #f) ; 已打开视图
        'tree-view-active '((255 214 120) . #f) ; 编辑格正在显示的视图
        'tree-view-hidden '((120 120 135) . #f) ; 当前没显示的视图
        'status      '((225 225 225) . (40 44 52))
        'separator   '((80 85 95) . #f)))

;; → (values fg bg)；未知 face 用浅灰。
(define (face-colors face)
  (define p (hash-ref theme face #f))
  (if p (values (car p) (cdr p)) (values '(205 205 205) #f)))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define-values (fg bg) (face-colors 'tree-dir))
  (check-equal? fg '(120 180 240))
  (check-false bg)
  (define-values (rfg _rbg) (face-colors 'tree-root))
  (check-equal? rfg '(240 150 60))
  (define-values (sfg sbg) (face-colors 'status))
  (check-equal? sbg '(40 44 52))
  (define-values (ufg _) (face-colors 'nope))
  (check-equal? ufg '(205 205 205))

  (displayln "lab-rebuild/theme.rkt: all tests passed"))

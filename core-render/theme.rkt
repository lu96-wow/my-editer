#lang racket

;;; core-render/theme.rkt —— theme 函数：用 racket-tui 的样式表定义颜色
;;;
;;; 后端不实现自己的 theme / style 结构，直接复用 racket-tui 的
;;; style-define! / style->bytes 双表（256/16 自动回退）。
;;; 这里只提供：
;;;   · define-styles!      —— 数据驱动地批量 style-define!
;;;   · install-default-theme! —— 内置一套默认颜色
;;;
;;; face 的分量（fg/bg/attrs）就是这张表里的名字：
;;;   face-fg = 'syntax-keyword  -> (style-define! 'syntax-keyword (color-rgb-fg …))
;;;   face-bg = 'bracket-0       -> (style-define! 'bracket-0      (color-rgb-bg …))
;;;   attrs   = '(bold)          -> (style-define! 'bold          attr-bold)
;;; 渲染端只管 (style->bytes 名字) 拼接，不关心它是前景还是背景。

(require "backend.rkt")

(provide define-styles! install-default-theme! default-styles)

;; entries : (listof (list name spec ...))
;; spec 是 tui 的颜色 / 属性 thunk（color-rgb-fg / color-256-bg / attr-bold …）。
(define (define-styles! entries)
  (for-each (λ (e) (apply style-define! e)) entries))

;; 内置默认主题。前缀约定：
;;   fg-*      前景色名
;;   bg-*      背景色名
;;   attr-*    属性名（bold / italic / …）
;;   UI        光标 / 选区 overlay
(define default-styles
  (list
   ;; 行号 / 正文
   (list 'fg-default      (color-rgb-fg 200 200 200))
   (list 'bg-default      (color-rgb-bg 20 22 28))
   (list 'line-number (color-rgb-fg 128 128 140))
   (list 'fg-line-number  (color-rgb-fg 128 128 140))
   (list 'fg-dim          (color-rgb-fg 120 120 130))

   ;; 语法
   (list 'fg-syntax-def     (color-rgb-fg 120 180 240))
   (list 'fg-syntax-control (color-rgb-fg 230 150 180))
   (list 'fg-syntax-macro   (color-rgb-fg 190 150 240))
   (list 'fg-syntax-binding (color-rgb-fg 235 190 110))
   (list 'fg-syntax-module  (color-rgb-fg 120 200 200))
   (list 'fg-syntax-string  (color-rgb-fg 190 220 140))
   (list 'fg-syntax-comment (color-rgb-fg 120 120 130))
   (list 'fg-syntax-number  (color-rgb-fg 200 170 240))

   ;; 括号深度（背景）
   (list 'bg-bracket-0 (color-rgb-bg 36 40 58))
   (list 'bg-bracket-1 (color-rgb-bg 28 47 49))
   (list 'bg-bracket-2 (color-rgb-bg 48 46 30))
   (list 'bg-bracket-3 (color-rgb-bg 30 49 40))

   ;; 装饰背景
   (list 'bg-word-mark (color-rgb-bg 60 70 90))
   (list 'bg-sync-mark (color-rgb-bg 60 95 80))

   ;; 属性
   (list 'bold      attr-bold)
   (list 'dim       attr-dim)
   (list 'italic    attr-italic)
   (list 'underline attr-underline)
   (list 'blink     attr-blink)

   ;; overlay（patch.rkt 里的语义角色：'cursor / 'cursor-secondary / 'selection）
   (list 'cursor           attr-reverse)                    ; 主光标：反显块
   (list 'cursor-secondary attr-underline)                  ; 副光标：下划线（可改反显 / 底色）
   (list 'selection        (color-rgb-bg 60 70 90))))      ; 选区：底色

(define (install-default-theme!)
  (define-styles! default-styles))

(module+ main
  (install-default-theme!)
  (require rackunit)
  (check-not-false (memq 'fg-syntax-def (map car default-styles)))
  (check-not-false (non-empty? (style->bytes 'fg-syntax-def)))
  (displayln "theme.rkt: ok"))

(define (non-empty? xs)
  (cond [(bytes? xs) (> (bytes-length xs) 0)]
        [(list? xs) (pair? xs)]
        [else #f]))

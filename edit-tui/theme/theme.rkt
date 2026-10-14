#lang racket

;;; edit/theme/theme.rkt —— 统一主题：face 符号 -> 样式（fg bg attrs）
;;;
;;; **字段和渲染层 face 一致**：fg / bg / attrs。
;;; 渲染层（core-render/face.rkt）的 face 三分量是符号；主题把每个符号解释成具体样式：
;;;
;;;   fg    : #f | (rgb r g b) | 0..255（256 色）
;;;   bg    : 同上
;;;   attrs : (listof (or 'bold 'dim 'italic 'underline 'blink))
;;;
;;; 安装时转成 racket-tui 的样式表（style-define!）；渲染层用 style->bytes 取转义序列。
;;; core 的 face（语法 / 光标 / 选区…）和 layout 的边框 face 都在这张表里 —— 一个主题。

(require tui)

(provide (struct-out rgb) (struct-out style)
         default-theme define-theme! install-default-theme!)

;; 真彩色；整数色号（0..255）直接用 fixnum。
(struct rgb (r g b) #:prefab)
;; 样式：和 face 同字段 fg / bg / attrs。
(struct style (fg bg attrs) #:prefab)

;;; ---------- 字段 -> tui 构造器 ----------

(define (color-fg-thunk c)
  (cond [(rgb? c) (color-rgb-fg (rgb-r c) (rgb-g c) (rgb-b c))]
        [(exact-nonnegative-integer? c) (color256-fg c)]
        [else #f]))

(define (color-bg-thunk c)
  (cond [(rgb? c) (color-rgb-bg (rgb-r c) (rgb-g c) (rgb-b c))]
        [(exact-nonnegative-integer? c) (color256-bg c)]
        [else #f]))

(define (attr-thunk a)
  (case a
    [(bold) attr-bold] [(dim) attr-dim] [(italic) attr-italic]
    [(underline) attr-underline] [(blink) attr-blink] [(reverse) attr-reverse]
    [else #f]))

(define (install-style! name st)
  (apply style-define! name
         (filter values
                 (append (list (color-fg-thunk (style-fg st))
                               (color-bg-thunk (style-bg st)))
                         (for/list ([a (in-list (style-attrs st))]) (attr-thunk a))))))

;; entries : (listof (list name style))。同名可覆盖。
(define (define-theme! entries)
  (for ([e (in-list entries)]) (install-style! (car e) (cadr e))))

;;; ---------- 默认主题（core face + layout 边框 face） ----------

(define default-theme
  (list
   ;; 行号 / 正文 / 属性
   (list 'fg-default      (style (rgb 200 200 200) #f '()))
   (list 'bg-default      (style #f (rgb 20 22 28) '()))
   (list 'line-number     (style (rgb 128 128 140) #f '()))
   (list 'fg-dim          (style (rgb 120 120 130) #f '()))
   (list 'bold            (style #f #f '(bold)))
   (list 'dim             (style #f #f '(dim)))
   (list 'italic          (style #f #f '(italic)))
   (list 'underline       (style #f #f '(underline)))
   (list 'blink           (style #f #f '(blink)))

   ;; 语法
   (list 'fg-syntax-def     (style (rgb 120 180 240) #f '()))
   (list 'fg-syntax-control (style (rgb 230 150 180) #f '()))
   (list 'fg-syntax-macro   (style (rgb 190 150 240) #f '()))
   (list 'fg-syntax-binding (style (rgb 235 190 110) #f '()))
   (list 'fg-syntax-module  (style (rgb 120 200 200) #f '()))
   (list 'fg-syntax-string  (style (rgb 190 220 140) #f '()))
   (list 'fg-syntax-comment (style (rgb 120 120 130) #f '(italic)))
   (list 'fg-syntax-number  (style (rgb 200 170 240) #f '()))

   ;; 括号深度（背景）
   (list 'bg-bracket-0 (style #f (rgb 36 40 58) '()))
   (list 'bg-bracket-1 (style #f (rgb 28 47 49) '()))
   (list 'bg-bracket-2 (style #f (rgb 48 46 30) '()))
   (list 'bg-bracket-3 (style #f (rgb 30 49 40) '()))

   ;; 装饰背景
   (list 'bg-word-mark (style #f (rgb 60 70 90) '()))
   (list 'bg-sync-mark (style #f (rgb 60 95 80) '()))

   ;; overlay（patch.rkt 语义角色）
   (list 'cursor           (style #f #f '(reverse)))
   (list 'cursor-secondary (style #f #f '(underline)))
   (list 'selection        (style #f (rgb 60 70 90) '()))

   ;; 边框（layout 的 panel face）
   (list 'window-border  (style (rgb 90 96 110) #f '()))
   (list 'focused-border (style (rgb 120 180 240) #f '()))
   (list 'float-border   (style (rgb 190 150 240) #f '()))))

(define (install-default-theme!)
  (define-theme! default-theme))

(module+ main
  (install-default-theme!)
  (require rackunit)
  (check-not-false (non-empty? (style->bytes 'fg-syntax-def)))
  (check-not-false (non-empty? (style->bytes 'window-border)))
  (displayln "theme.rkt: ok"))

(define (non-empty? xs)
  (cond [(bytes? xs) (> (bytes-length xs) 0)]
        [(list? xs) (pair? xs)]
        [else #f]))

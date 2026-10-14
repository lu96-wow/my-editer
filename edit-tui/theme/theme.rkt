#lang racket

;;; edit-tui/theme/theme.rkt —— 主题机制（字段与渲染层 face 一致）
;;;
;;; 一个 style 就是 fg / bg / attrs（和 core-render/face.rkt 的 face 同字段）：
;;;   fg / bg : #f | (rgb r g b) | 0..255
;;;   attrs   : (listof (or 'bold 'dim 'italic 'underline 'blink 'reverse))
;;;
;;; define-theme! 把 style 值转成 racket-tui 的样式（style-define!）；
;;; 渲染层用 style->bytes 取转义序列。
;;;
;;; 主题**数据**分两份（后面还能再拆）：
;;;   core.rkt    渲染核心：正文 / 语法 / 光标 / 选区
;;;   frame.rkt   框架：窗口 / 聚焦 / 浮窗边框
;;; 入口 main.rkt：require 即安装。

(require tui)

(provide (struct-out rgb) (struct-out style) define-theme!)

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

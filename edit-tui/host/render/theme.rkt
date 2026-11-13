#lang racket

;;; edit-tui/host/render/theme.rkt —— 把命名样式安装进 tui 样式表
;;;
;;; 主题数据在 config/theme/；这里只做 style -> tui style-define!。
;;; 纯值 / 副作用分开：配置层不 require tui，也不在 require 时安装。

(require tui
         "../../core/face/api.rkt")

(provide install-theme!)

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
    [(bold) attr-bold]
    [(dim) attr-dim]
    [(italic) attr-italic]
    [(underline) attr-underline]
    [(blink) attr-blink]
    [(reverse) attr-reverse]
    [else #f]))

(define (install-style! name st)
  (apply style-define! name
         (filter values
                 (append (list (color-fg-thunk (style-fg st))
                               (color-bg-thunk (style-bg st)))
                         (for/list ([a (in-list (style-attrs st))])
                           (attr-thunk a))))))

;; entries : (listof (list name style))
(define (install-theme! entries)
  (for ([e (in-list entries)])
    (install-style! (car e) (cadr e))))

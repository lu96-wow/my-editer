#lang racket

;;; edit-tui-rebuild/render/theme.rkt —— style / theme（纯数据 + tui 样式表安装）
;;;
;;; fg / bg : #f | (rgb r g b) | 0..255
;;; attrs   : (listof 'bold 'dim 'italic 'underline 'blink 'reverse)

(require tui)

(provide (struct-out rgb)
         (struct-out style)
         define-theme!)

(struct rgb (r g b) #:prefab)
(struct style (fg bg attrs) #:prefab)

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

(define (define-theme! entries)
  (for ([e (in-list entries)])
    (install-style! (car e) (cadr e))))

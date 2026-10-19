#lang racket

;;; edit-tui-rebuild/render/theme.rkt —— style / theme（纯数据 + tui 样式表安装）
;;;
;;; fg / bg : #f | (rgb r g b) | 0..255
;;; attrs   : (listof 'bold 'dim 'italic 'underline 'blink 'reverse)

(require tui)

(provide (struct-out rgb)
         (struct-out style)
         define-theme!
         default-theme
         install-default-theme!)

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

(define default-theme
  (list
   ;; 基础
   (list 'fg-default   (style #f #f '()))
   (list 'bg-default   (style #f #f '()))
   (list 'fg-dim       (style (rgb 120 120 130) #f '()))
   (list 'line-number  (style (rgb 120 120 130) #f '()))
   (list 'bold         (style #f #f '(bold)))
   (list 'dim          (style #f #f '(dim)))
   (list 'italic       (style #f #f '(italic)))
   (list 'underline    (style #f #f '(underline)))
   (list 'blink        (style #f #f '(blink)))

   ;; 边框
   (list 'window-border   (style (rgb 105 112 128) #f '()))
   (list 'focused-border  (style (rgb 120 180 240) #f '()))
   (list 'float-border    (style (rgb 190 150 240) #f '()))

   ;; chrome / 资源
   (list 'status-bar        (style (rgb 225 225 225) (rgb 40 44 52) '()))
   (list 'status-mode       (style (rgb 120 210 130) #f '(bold)))
   (list 'status-dirty      (style (rgb 230 160 90) #f '(bold)))
   (list 'message           (style (rgb 230 160 90) #f '()))
   (list 'input             (style #f #f '()))
   (list 'resource-document (style (rgb 200 200 200) #f '()))
   (list 'resource-view     (style (rgb 140 160 190) #f '()))
   (list 'resource-focus    (style (rgb 120 210 130) #f '(bold)))
   (list 'resource-pending  (style (rgb 230 160 90) #f '(bold)))

   ;; overlay
   (list 'cursor    (style #f #f '(reverse)))
   (list 'selection (style #f (rgb 60 70 90) '()))))

(define (install-default-theme!)
  (define-theme! default-theme))

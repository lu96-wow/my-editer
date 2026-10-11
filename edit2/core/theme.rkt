#lang racket

;;; edit2/theme.rkt —— face → ANSI 属性（骨架：先做属性，颜色后可加）
;;;
;;; core 的 piece-attr 形态：
;;;   (render face)     普通文本格，face = 符号 | #f
;;;   (cursor . face)   光标格
;;;   (selection . face) 选区格
;;; 这里把属性翻成字节；后端只调 attr-bytes。

(provide face-bytes attr-bytes)

(require (prefix-in t: tui))

(define (face-bytes f)
  (case f
    [(dim)      t:format-dim]
    [(bold)     t:format-bold]
    [(accent)   t:format-bold]
    [(italic)   t:format-italic]
    [(underline) t:format-underline]
    [else #""]))

(define (attr-bytes attr)
  (cond
    [(and (pair? attr) (eq? (car attr) 'cursor))    (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'selection)) (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'render))    (face-bytes (cadr attr))]
    [else #""]))

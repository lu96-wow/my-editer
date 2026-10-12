#lang racket

;;; edit4/view/theme.rkt —— face → ANSI 字节（最小版）
;;;
;;; 主题是纯编码器：把 piece 的 attr 翻成字节。不认识 World。
;;; 后续扩展：调色板、face-stack 分层、真彩/256 色。

(provide attr-bytes face-bytes)

(require (prefix-in t: tui))

(define (face-bytes f)
  (cond
    [(eq? f 'window-border) t:format-dim]
    [(not f) #""]
    [else #""]))

;; core piece attr 形态：
;;   (render face) | (cursor . face) | (selection . face) | 普通 face
(define (attr-bytes a)
  (cond
    [(and (pair? a) (eq? 'cursor (car a))) (bytes-append (face-bytes (cdr a)) t:format-reverse)]
    [(and (pair? a) (eq? 'selection (car a))) (bytes-append (face-bytes (cdr a)) t:format-reverse)]
    [(and (pair? a) (eq? 'render (car a))) (face-bytes (cadr a))]
    [else (face-bytes a)]))

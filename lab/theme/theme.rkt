#lang racket

(require "../base/face.rkt")

;;; lab/theme/theme.rkt —— 主题机制（纯）
;;;
;;; 主题 = face / overlay 符号 → 颜色。颜色是 #f（不设，交给默认）或 (r g b)（各分量 0-255）。
;;; 本文件不认识终端 / ANSI / racket-tui —— 后端负责把颜色翻成转义序列。
;;;
;;;   faces          : hash  face-symbol   -> (list fg bg)
;;;   overlays       : hash  overlay-symbol -> (list fg bg)
;;;   default-face   : (list fg bg)          未登记 face 的回落
;;;   bracket-colors : vector of (list fg bg)  括号背景色板，按嵌套深度取模
;;;
;;; 动态 face（见 base/face.rkt）：bracket-depth 按 n 在 bracket-colors 上取模。

(provide (struct-out theme)
         theme-face-colors theme-overlay-colors)

(struct theme (faces overlays default-face bracket-colors) #:transparent)

(define (theme-face-colors t face)
  (cond
    [(bracket-depth? face)
     (define v (theme-bracket-colors t))
     (cond
       [(zero? (vector-length v)) (values #f #f)]
       [else
        (define c (vector-ref v (modulo (bracket-depth-n face) (vector-length v))))
        (values (car c) (cadr c))])]
    [else
     (define c (or (hash-ref (theme-faces t) face #f) (theme-default-face t)))
     (values (car c) (cadr c))]))

(define (theme-overlay-colors t ov)
  (define c (hash-ref (theme-overlays t) ov #f))
  (if c (values (car c) (cadr c)) (values #f #f)))

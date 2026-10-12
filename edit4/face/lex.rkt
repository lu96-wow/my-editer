#lang racket

;;; edit4/face/lex.rkt —— 行内标识符扫描（纯）
;;;
;;; 「什么算一个词」的单一来源。用 char-alphabetic?/char-numeric?（Racket regexp 不支持 \p{L}）。

(provide symbol-char? ident-start? ident-char? line-tokens)

(define symbol-extra (string->list "!$%&*/:<=>?^_~#@+-.\\"))

(define (symbol-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (memv c symbol-extra)))
(define (ident-start? c) (or (char-alphabetic? c) (char=? c #\_)))
(define (ident-char? c) (symbol-char? c))

(define (line-tokens line)
  (define n (string-length line))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [(ident-start? (string-ref line i))
       (define j (let next ([j (add1 i)])
                   (if (and (< j n) (ident-char? (string-ref line j))) (next (add1 j)) j)))
       (loop j (cons (cons i j) acc))]
      [else (loop (add1 i) acc)])))

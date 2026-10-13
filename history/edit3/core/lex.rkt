#lang racket

;;; edit3/lex.rkt —— 行内标识符扫描（纯）
;;;
;;; 「什么算一个词」的单一来源：高亮插件共用。
;;;   首字符：Unicode 字母 / 下划线；后续：Unicode 字母 / 数字 / symbol 字符。
;;; ⚠ 用 char-alphabetic? / char-numeric? 而非正则字符类（Racket regexp 不支持 \p{L}，
;;;   中文等 CJK 会漏）。

(provide symbol-char? ident-start? ident-char? line-tokens)

(define symbol-extra (string->list "!$%&*/:<=>?^_~#@+-.\\"))

(define (symbol-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (memv c symbol-extra)))
(define (ident-start? c) (or (char-alphabetic? c) (char=? c #\_)))
(define (ident-char? c) (symbol-char? c))

;; 一行里的标识符区间 (start . end)。
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

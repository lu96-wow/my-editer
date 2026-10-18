#lang racket

;;; layer  : plugins/lang
;;; effect : 无（纯：文本 + 行/列 -> 词）
;;;
;;; word.rkt —— “词”的唯一定义（补全 / 文档 / 高亮共用）
;;;
;;; symbol-char? 是 Racket 风格标识符字符集；word-before 取光标左侧紧邻的
;;; 连续词字符：
;;;   · 补全把它当前缀（边打边筛）；
;;;   · 文档按「光标前词」查询，而不是光标所在格上的词。
;;;
;;; 只按**行内字符**切词，不跨行；line / col 0-based。对任意编辑中的文本
;;; （包括空行 / 越界位置）都是全函数。

(provide symbol-char?
         ident-start?
         line-tokens
         word-before)

(require racket/string)

(define (symbol-char? c)
  (or (char-alphabetic? c) (char-numeric? c)
      (memv c '(#\- #\_ #\? #\! #\* #\/ #\> #\< #\= #\+ #\. #\% #\& #\:))))

;; 标识符起始：字母 / 下划线（数字开头的不是词，避免把 42 当候选）。
(define (ident-start? c)
  (or (char-alphabetic? c) (char=? c #\_)))

;; 一行里的标识符 token → (listof (cons start end))。
;; 词高亮、当前词高亮、补全都走这一份切分，保证“词”的定义一致。
(define (line-tokens line)
  (define n (string-length line))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [(ident-start? (string-ref line i))
       (define j (let next ([j (add1 i)])
                   (if (and (< j n) (symbol-char? (string-ref line j))) (next (add1 j)) j)))
       (loop j (cons (cons i j) acc))]
      [else (loop (add1 i) acc)])))

;; text line col -> 光标左侧紧邻的连续词字符（无 -> ""）。
(define (word-before text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (define l (cond [(and (exact-nonnegative-integer? line) (< line (length lines)))
                   (list-ref lines line)]
                  [else ""]))
  (define c (min (max 0 (if (exact-nonnegative-integer? col) col 0))
                 (string-length l)))
  (define start
    (let loop ([i c])
      (if (and (> i 0) (symbol-char? (string-ref l (sub1 i))))
          (loop (sub1 i))
          i)))
  (substring l start c))

#lang racket

;;; edit/core/lex.rkt —— 共享词法器：按行扫标识符 token（纯）
;;;
;;; 「什么算一个词」的单一来源：着色插件与将来补全共用，保证两边认的词一致。
;;;   token = (list line start end text)
;;;   首字符：Unicode 字母 / 下划线
;;;   后续  ：Unicode 字母 / 数字 / symbol-char?
;;; 不处理字符串 / 注释 / 字符字面量 —— 玩具级，够高亮与补全用。
;;;
;;; ⚠ 用 char-alphabetic? / char-numeric? 而不是正则字符类：Racket regexp 不支持
;;;    \p{L}（[:alpha:] 也是 ASCII-only），中文等 CJK 会被漏掉。

(require racket/string)

(provide symbol-char? ident-start? ident-char?
         line-tokens scan-words)

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

;; 整篇 → (listof token)。
(define (scan-words text)
  (append*
   (for/list ([line (in-list (string-split text "\n"))] [ln (in-naturals)])
     (for/list ([m (in-list (line-tokens line))])
       (list ln (car m) (cdr m) (substring line (car m) (cdr m)))))))

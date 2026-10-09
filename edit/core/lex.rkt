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
         line-tokens scan-words active-token
         line-at prefix-at)

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

;; 「正在输入的那个词」= 光标前一个字符所在的 token（point = (cons line col) | #f）。
;; 词高亮 / 关键字都跳过它，等词定下来（敲分隔符 / 移开）再上色，免得边打边换色。
(define (active-token tokens point)
  (and point
       (let ([line (car point)] [col (sub1 (cdr point))])
         (and (>= col 0)
              (for/first ([tok (in-list tokens)]
                          #:when (and (= line (car tok)) (<= (cadr tok) col) (< col (caddr tok))))
                tok)))))

;; 第 line 行字符串（不含换行；越界 = ""）。
(define (line-at text line)
  (define n (string-length text))
  (define (scan-nl j) (if (or (>= j n) (char=? (string-ref text j) #\newline)) j (scan-nl (add1 j))))
  (let loop ([i 0] [ln 0])
    (cond
      [(= ln line) (substring text i (scan-nl i))]
      [(>= i n) ""]
      [else (define nl (scan-nl i)) (loop (add1 nl) (add1 ln))])))

;; 光标左侧的标识符前缀（补全用；无 → ""）。
(define (prefix-at text line col)
  (define s (line-at text line))
  (define n (string-length s))
  (define c (max 0 (min col n)))
  (define start
    (let loop ([i c])
      (if (and (> i 0) (symbol-char? (string-ref s (sub1 i)))) (loop (sub1 i)) i)))
  (substring s start c))

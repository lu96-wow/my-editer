#lang racket

;;; lab/builtin/lang/ident.rkt —— 文本层：行 / 光标处的标识符 / 前缀（纯）
;;;
;;; 语言服务（文档查询 / 补全）只吃「纯文本 + 行号列号」。本文件不认识
;;; editor / app / 插件，只做词法切分：
;;;
;;;   line-at       text line -> 该行字符串（不含换行；越界 = ""）
;;;   identifier-at text line col -> 光标处标识符（可含左右半边；无 -> #f）
;;;   prefix-at     text line col -> 光标左侧的标识符前缀（补全用；无 -> ""）
;;;
;;; 列号是 0-based。标识符字符集见 lex.rkt（唯一来源）：字母 / 数字 / 一批符号字符。

(provide symbol-char? line-at identifier-at prefix-at)

(require racket/string
         "lex.rkt")

(define (line-at text line)
  (define lines (string-split text "\n" #:trim? #f))
  (if (and (>= line 0) (< line (length lines))) (list-ref lines line) ""))

;; 光标处标识符：光标正好在某字符上 → 连左右；光标紧跟在词尾 → 只取左侧。
(define (identifier-at text line col)
  (define s (line-at text line))
  (define n (string-length s))
  (define c (max 0 (min col n)))
  (define on-char? (and (< c n) (symbol-char? (string-ref s c))))
  (define left-char? (and (> c 0) (symbol-char? (string-ref s (sub1 c)))))
  (cond
    [(or on-char? left-char?)
     (define start
       (let loop ([i (if on-char? c (sub1 c))])
         (if (and (> i 0) (symbol-char? (string-ref s (sub1 i)))) (loop (sub1 i)) i)))
     (define end
       (let loop ([i c])
         (if (and (< i n) (symbol-char? (string-ref s i))) (loop (add1 i)) i)))
     (substring s start end)]
    [else #f]))

;; 补全前缀：从光标往左连续吃标识符字符。
(define (prefix-at text line col)
  (define s (line-at text line))
  (define n (string-length s))
  (define c (max 0 (min col n)))
  (define start
    (let loop ([i c])
      (if (and (> i 0) (symbol-char? (string-ref s (sub1 i)))) (loop (sub1 i)) i)))
  (substring s start c))

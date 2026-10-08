#lang racket

;;; lab/builtin/lang/lex.rkt —— 共享词法器：按行扫标识符 token（纯原子）
;;;
;;; 「什么算一个词」的**单一来源**。属性插件（词着色 / 关键字）与补全都 require 本文件，
;;; 保证「着色的词」「补全认的词」「前缀取的词」完全一致。
;;; （此前 highlight/lex.rkt 与 lang/ident.rkt 各有一套字符集，已经漂移：
;;;   `foo_bar` 在一处是一个词、在另一处是两个；`$%&^~#@\` 有的认有的不认。）
;;;
;;; token = (list line start end text)。
;;;   首字符：Unicode 字母 / 下划线
;;;   后续  ：Unicode 字母 / 数字 / symbol-char?（含 !$%&*/:<=>?^_~#@+-.\）
;;; 不处理字符串 / 注释 / 字符字面量 —— 玩具级，够高亮与补全用。
;;;
;;; ⚠ 用 char-alphabetic? / char-numeric? 而不是正则字符类：Racket 的 regexp
;;; 引擎不支持 \p{L}（POSIX [:alpha:] 也是 ASCII-only），中文等 CJK 会被漏掉。

(require "../../kernel/api.rkt")

(provide symbol-char? ident-start? ident-char?
         line-tokens scan-words word-token-at active-token)

(define symbol-extra (string->list "!$%&*/:<=>?^_~#@+-.\\"))

;; Racket 标识符里允许出现的字符（近似）。前缀切分（lang/ident）也用它。
(define (symbol-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (memv c symbol-extra)))

(define (ident-start? c) (or (char-alphabetic? c) (char=? c #\_)))

;; 标识符后续字符 = symbol-char?（与补全前缀同一套）。
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

(define (scan-words text)
  (append*
   (for/list ([line (in-list (string->lines text))] [ln (in-naturals)])
     (for/list ([m (in-list (line-tokens line))])
       (list ln (car m) (cdr m) (substring line (car m) (cdr m)))))))

;; 第 line 行第 col 个字符落在哪个标识符 token 里 → (list start end) / #f。
(define (word-token-at line col)
  (for/first ([m (in-list (line-tokens line))]
              #:when (and (<= (car m) col) (< col (cdr m))))
    (list (car m) (cdr m))))

;; “正在输入的那个词” = 光标（编辑插入文本末尾）前一个字符所在的 token。
;; 词着色 / 关键字都跳过它，等词定下来再上色 —— 否则边打字边加长会每键换色。
;; → #f | (list line start end)；多编辑 / 越界 → #f。
(define (active-token lines edits)
  (and (= 1 (length edits))
       (let* ([e (car edits)]
              [l0 (list-ref e 0)] [c0 (list-ref e 1)]
              [inserted (list-ref e 4)]
              [parts (string->lines inserted)]
              [pt (if (= 1 (length parts))
                      (list l0 (+ c0 (string-length inserted)))
                      (list (+ l0 (sub1 (length parts))) (string-length (last parts))))]
              [ln (car pt)])
         (and (< ln (vector-length lines))
              (let* ([line (vector-ref lines ln)]
                     [col (max 0 (sub1 (cadr pt)))])
                (and (< col (string-length line))
                     (let ([t (word-token-at line col)])
                       (and t (list ln (car t) (cdr t))))))))))

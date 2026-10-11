#lang racket

;;; edit-rebuild/core/face/lex.rkt —— 共享词法器：按行扫标识符 token（纯）
;;;
;;; 「什么算一个词」的单一来源：着色插件与将来补全共用，保证两边认的词一致。
;;;   token = (list line start end text)
;;;   首字符：Unicode 字母 / 下划线
;;;   后续  ：Unicode 字母 / 数字 / symbol-char?
;;; 不处理字符串 / 注释 / 字符字面量 —— 玩具级，够高亮与补全用。
;;;
;;; ⚠ 用 char-alphabetic? / char-numeric? 而不是正则字符类：Racket regexp 不支持
;;;    \p{L}（[:alpha:] 也是 ASCII-only），中文等 CJK 会被漏掉。

(require racket/string
         "../../../core/text/base/line.rkt"
         "../../../core/text/base/track.rkt"
         "../../../core/text/base/change.rkt"
         "../../../core/text/base/point.rkt"
         "../../../core/text/base/range.rkt")

(provide symbol-char? ident-start? ident-char?
         line-tokens scan-words word-token-at word-token-at-cursor cursor-word
         edit-word line-at prefix-at identifier-at)

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

;; 整篇 → (listof token)。行切分与 document 一致（string->lines，保留空行）。
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

;; 光标处 token：包含 col，或**恰在 col 结束**（光标紧跟词尾，如刚敲完）→ (list start end) / #f。
(define (word-token-at-cursor line col)
  (or (word-token-at line col)
      (for/first ([m (in-list (line-tokens line))]
                  #:when (= (cdr m) col))
        (list (car m) (cdr m)))))

;; 光标点 (cons line col) 处的词 → (list line start end) | #f。
(define (cursor-word text cursor)
  (cond
    [(not cursor) #f]
    [else
     (define line (car cursor))
     (define col (cdr cursor))
     (cond
       [(or (< line 0) (>= line (track-length text))) #f]
       [else
        (define ln (track-ref text line))
        (cond
          [(or (< col 0) (> col (string-length ln))) #f]
          [else
           (define tok (word-token-at-cursor ln col))
           (and tok (list line (car tok) (cadr tok)))])])]))

;; 一次编辑「正在输入的词」= 插入点（after 区间末尾）前一个字符所在 token
;; → (list line start end) | #f。**不依赖光标**：只读 change 与文本，
;; 所以移动光标不改变它。多个 change / 删除边界 → #f。
(define (edit-word changes text)
  (cond
    [(not (= 1 (length changes))) #f]
    [else
     (define r (change-post-range (car changes)))
     (define line (point-line (range-end r)))
     (define col (sub1 (point-column (range-end r))))
     (cond
       [(or (< col 0) (>= line (track-length text))) #f]
       [else
        (define ln (track-ref text line))
        (cond
          [(>= col (string-length ln)) #f]
          [else (define tok (word-token-at ln col))
                (and tok (list line (car tok) (cadr tok)))])])]))

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

;; 光标处标识符（文档查询 / 悬停用）：光标在某字符上 → 连左右；紧跟词尾 → 只取左侧。
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

#lang racket

;;; edit-tui/lang/racket/lex.rkt —— Racket 词法切片（纯）
;;;
;;; 只做语法高亮 / 同词着色 / 补全共用的“行内 token”：
;;;   source text -> (listof (listof token))
;;;
;;; token 只描述区间和类别，不产生 face；配色是上层（highlight / word-color）
;;; 的策略。这样同一份词法结果可以被多个语言功能复用。
;;;
;;; 跨行状态 = (block-depth . in-string?)
;;;   block-depth : #| … |# 可嵌套
;;;   in-string?  : Racket 字符串可以跨行
;;;
;;; 本模块不 require app / boot / core，保持可单独测试。

(provide (struct-out token)
         token-kind token-start token-end
         empty-lex-state
         tokenize-line
         tokenize
         line-token-at
         identifier-at)

(struct token (kind start end) #:transparent)
;; kind  : 'comment | 'string | 'char | 'number | 'symbol
;;       | 'paren | 'whitespace | 'other
;; start : 行内 0-based 起始列（含）
;; end   : 行内 0-based 结束列（不含）

(define empty-lex-state (cons 0 #f))

;;; ════════════════ 字符判定 ════════════════

(define (delimiter? c)
  (or (char-whitespace? c)
      (memv c '(#\( #\) #\[ #\] #\{ #\}
                #\" #\; #\' #\` #\,))))

(define (symbol-char? c)
  (and (not (delimiter? c))
       (not (char=? c #\\))))

(define (paren-char? c)
  (memv c '(#\( #\) #\[ #\] #\{ #\})))

(define (whitespace-char? c) (char-whitespace? c))

;;; ════════════════ 行扫描 ════════════════

;; → (values state' (listof token))
;; state = (cons block-depth in-string?)
;;
;; 说明：字符串 / 块注释跨行时，每一行都产出一个对应类别的 token。
;; 同一行里相邻的同类 token 会合并，避免 1000 个单字符 token。
(define (tokenize-line state line)
  (define n (string-length line))
  (define out '())
  (define (emit! kind start end)
    (when (< start end)
      (define prev (and (pair? out) (car out)))
      (set! out
            (cond
              [(and prev
                    (eq? (token-kind prev) kind)
                    (= (token-end prev) start))
               (cons (token kind (token-start prev) end) (cdr out))]
              [else (cons (token kind start end) out)]))))
  (define (emit-flat! kind start end)
    ;; 不合并（用于需要保持词法边界的场景；目前等价于 emit!）
    (emit! kind start end))

  (let loop ([i 0]
             [block (car state)]
             [in-string? (cdr state)]
             [comment-start (and (positive? (car state)) 0)]
             [string-start (and (cdr state) 0)])
    (cond
      [(>= i n)
       (when comment-start (emit-flat! 'comment comment-start n))
       (when string-start (emit-flat! 'string string-start n))
       (values (cons block in-string?) (reverse out))]

      ;; ---------- 块注释 ----------
      [(positive? block)
       (cond
         [(and (< (add1 i) n)
               (char=? #\# (string-ref line i))
               (char=? #\| (string-ref line (add1 i))))
          (loop (+ i 2) (add1 block) in-string? comment-start string-start)]
         [(and (< (add1 i) n)
               (char=? #\| (string-ref line i))
               (char=? #\# (string-ref line (add1 i))))
          (define block* (sub1 block))
          (cond
            [(zero? block*)
             (emit-flat! 'comment comment-start (+ i 2))
             (loop (+ i 2) 0 in-string? #f string-start)]
            [else
             (loop (+ i 2) block* in-string? comment-start string-start)])]
         [else
          (loop (add1 i) block in-string? comment-start string-start)])]

      ;; ---------- 字符串 ----------
      [in-string?
       (cond
         [(char=? #\\ (string-ref line i))
          (loop (min n (+ i 2)) block #t comment-start string-start)]
         [(char=? #\" (string-ref line i))
          (emit-flat! 'string string-start (add1 i))
          (loop (add1 i) block #f comment-start #f)]
         [else
          (loop (add1 i) block #t comment-start string-start)])]

      ;; ---------- 正常代码 ----------
      [else
       (define c (string-ref line i))
       (cond
         ;; 块注释开始
         [(and (< (add1 i) n)
               (char=? c #\#)
               (char=? #\| (string-ref line (add1 i))))
          (loop (+ i 2) 1 #f i #f)]

         ;; 行注释
         [(char=? c #\;)
          (emit-flat! 'comment i n)
          (loop n block #f #f #f)]

         ;; 字符串开始
         [(char=? c #\")
          (loop (add1 i) block #t #f i)]

         ;; 字符字面量 #\x / #\space / #\(
         [(and (< (add1 i) n)
               (char=? c #\#)
               (char=? #\\ (string-ref line (add1 i))))
          (define j (+ i 2))
          (define end
            (cond
              [(>= j n) n]
              [(char-alphabetic? (string-ref line j))
               (let next ([k j])
                 (if (and (< k n)
                          (or (char-alphabetic? (string-ref line k))
                              (char-numeric? (string-ref line k))))
                     (next (add1 k))
                     k))]
              [else (min n (add1 j))]))
          (emit-flat! 'char i end)
          (loop end block #f #f #f)]

         ;; 空白
         [(whitespace-char? c)
          (emit-flat! 'whitespace i (add1 i))
          (loop (add1 i) block #f #f #f)]

         ;; 括号
         [(paren-char? c)
          (emit-flat! 'paren i (add1 i))
          (loop (add1 i) block #f #f #f)]

         ;; 数字（足够高亮用：整数 / 小数；不试图完整实现 Racket 数字语法）
         [(char-numeric? c)
          (define end
            (let next ([k (add1 i)])
              (if (and (< k n)
                       (or (char-numeric? (string-ref line k))
                           (char=? #\. (string-ref line k))))
                  (next (add1 k))
                  k)))
          (emit-flat! 'number i end)
          (loop end block #f #f #f)]

         ;; 符号 / 标识符
         [(symbol-char? c)
          (define end
            (let next ([k (add1 i)])
              (cond
                [(>= k n) k]
                [(not (symbol-char? (string-ref line k))) k]
                ;; 符号里遇到 #| / #; 时停下，交给外层当注释处理
                [(and (char=? #\# (string-ref line k))
                      (< (add1 k) n)
                      (or (char=? #\| (string-ref line (add1 k)))
                          (char=? #\; (string-ref line (add1 k)))))
                 k]
                [else (next (add1 k))])))
          (emit-flat! 'symbol i end)
          (loop end block #f #f #f)]

         ;; 其他单字符（引号 / quasiquote / unquote / 其他 reader 前缀）
         [else
          (emit-flat! 'other i (add1 i))
          (loop (add1 i) block #f #f #f)])])))

;;; ════════════════ 全文 ════════════════

;; → (listof (listof token))，每个元素对应一行（保留空行）。
(define (tokenize text)
  (define lines (string-split text "\n" #:trim? #f))
  (let loop ([lines lines] [state empty-lex-state] [acc '()])
    (cond
      [(null? lines) (reverse acc)]
      [else
       (define-values (state* toks) (tokenize-line state (car lines)))
       (loop (cdr lines) state* (cons toks acc))])))

;; 行内光标列 -> token | #f。
;; 光标恰好在 token 尾部时也算命中（补全 / 当前词常用“词后光标”）。
(define (line-token-at tokens col)
  (for/first ([t (in-list tokens)]
              #:when (and (<= (token-start t) col)
                          (or (< col (token-end t))
                              (and (= col (token-end t))
                                   (eq? (token-kind t) 'symbol)))))
    t))

;;; ════════════════ 光标处标识符 ════════════════

;; text / line / col（0-based） -> string | #f
;; 只看 symbol token；光标在词尾也算命中。
(define (identifier-at text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (length lines)))
     #f]
    [else
     (define src (list-ref lines line))
     (define toks (tokenize text))
     (define line-tokens (list-ref toks line))
     (define t (line-token-at line-tokens col))
     (and t
          (eq? (token-kind t) 'symbol)
          (substring src (token-start t) (min (token-end t) (string-length src))))]))

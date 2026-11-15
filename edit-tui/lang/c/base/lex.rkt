#lang racket

;;; edit-tui/lang/c/base/lex.rkt —— C 行内词法（纯）
;;;
;;; 目标是高亮 / 补全 / 文档查找共用，不实现完整 C 预处理器。
;;;
;;; token kind:
;;;   'comment 'string 'char 'number 'keyword 'type 'constant
;;;   'preprocessor 'identifier 'punct 'whitespace 'other
;;;
;;; 跨行状态只有块注释 / 字符串 / 字符字面量（C 字符串可用反斜杠续行）。
;;; 预处理器指令按“行首 # 到行尾”作为一个 token；足够高亮，不解析宏。

(require racket/list
         racket/string
         "keywords.rkt")

(provide (struct-out c-token)
         (struct-out c-lex-state)
         c-empty-lex-state
         c-tokenize-line
         c-tokenize
         c-line-token-at
         c-identifier-at
         c-symbols-in-text
         c-text-lines)

(struct c-token (kind start end) #:transparent)
(struct c-lex-state (block? in-string? in-char?) #:transparent)

(define c-empty-lex-state (c-lex-state #f #f #f))

(define (ch s i) (string-ref s i))

(define (ident-start? c)
  (or (char-alphabetic? c) (char=? c #\_)))

(define (ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

(define (digit? c) (char-numeric? c))

(define (two-char? s i a b)
  (and (< (add1 i) (string-length s))
       (char=? (ch s i) a)
       (char=? (ch s (add1 i)) b)))

(define (emit-token kind start end)
  (and (< start end) (c-token kind start end)))

(define (classify-ident s)
  (cond
    [(c-keyword? s) 'keyword]
    [(c-type? s) 'type]
    [(c-constant? s) 'constant]
    [else 'identifier]))

;; → (values c-lex-state' (listof c-token))
(define (c-tokenize-line state line)
  (define n (string-length line))
  (define out '())
  (define (emit! kind start end)
    (define t (emit-token kind start end))
    (when t (set! out (cons t out))))
  (define (finish block? in-string? in-char?)
    (values (c-lex-state block? in-string? in-char?) (reverse out)))
  (let loop ([i 0]
             [block? (c-lex-state-block? state)]
             [in-string? (c-lex-state-in-string? state)]
             [in-char? (c-lex-state-in-char? state)]
             [comment-start (and (c-lex-state-block? state) 0)]
             [string-start (and (c-lex-state-in-string? state) 0)]
             [char-start (and (c-lex-state-in-char? state) 0)]
             [line-start? #t])
    (cond
      [(>= i n)
       (when comment-start (emit! 'comment comment-start n))
       (when string-start (emit! 'string string-start n))
       (when char-start (emit! 'char char-start n))
       ;; 只有在行尾仍是反斜杠时才把字符串 / 字符带到下一行。
       (define continued? (and (positive? n) (char=? (ch line (sub1 n)) #\\)))
       (finish block?
               (and in-string? continued?)
               (and in-char? continued?))]

      ;; ---------- 块注释 ----------
      [block?
       (cond
         [(two-char? line i #\* #\/)
          (emit! 'comment comment-start (+ i 2))
          (loop (+ i 2) #f in-string? in-char? #f string-start char-start #f)]
         [else
          (loop (add1 i) #t in-string? in-char? comment-start string-start char-start #f)])]

      ;; ---------- 字符串 ----------
      [in-string?
       (cond
         [(char=? (ch line i) #\\)
          (loop (min n (+ i 2)) #f #t in-char? #f string-start char-start #f)]
         [(char=? (ch line i) #\")
          (emit! 'string string-start (add1 i))
          (loop (add1 i) #f #f in-char? #f #f char-start #f)]
         [else
          (loop (add1 i) #f #t in-char? #f string-start char-start #f)])]

      ;; ---------- 字符字面量 ----------
      [in-char?
       (cond
         [(char=? (ch line i) #\\)
          (loop (min n (+ i 2)) #f in-string? #t #f string-start char-start #f)]
         [(char=? (ch line i) #\')
          (emit! 'char char-start (add1 i))
          (loop (add1 i) #f in-string? #f #f string-start #f #f)]
         [else
          (loop (add1 i) #f in-string? #t #f string-start char-start #f)])]

      ;; ---------- 正常 ----------
      [else
       (define c (ch line i))
       (cond
         [(char-whitespace? c)
          (define end
            (let next ([k (add1 i)])
              (if (and (< k n) (char-whitespace? (ch line k))) (next (add1 k)) k)))
          (emit! 'whitespace i end)
          (loop end #f #f #f #f #f #f line-start?)]

         [(two-char? line i #\/ #\/)
          (emit! 'comment i n)
          (loop n #f #f #f #f #f #f #f)]

         [(two-char? line i #\/ #\*)
          (loop (+ i 2) #t #f #f i #f #f #f)]

         [(char=? c #\")
          (loop (add1 i) #f #t #f #f i #f #f)]

         [(char=? c #\')
          (loop (add1 i) #f #f #t #f #f i #f)]

         [(and (char=? c #\#) line-start?)
          (emit! 'preprocessor i n)
          (loop n #f #f #f #f #f #f #f)]

         [(ident-start? c)
          (define end
            (let next ([k (add1 i)])
              (if (and (< k n) (ident-char? (ch line k))) (next (add1 k)) k)))
          (define word (substring line i end))
          (emit! (classify-ident word) i end)
          (loop end #f #f #f #f #f #f #f)]

         [(digit? c)
          (define end
            (let next ([k (add1 i)])
              (define (num-char? x)
                (or (char-numeric? x)
                    (char-alphabetic? x)
                    (memv x '(#\. #\_ #\+ #\-))))
              (if (and (< k n)
                       (num-char? (ch line k))
                       ;; 只在指数 / 十六进制前后接受 +/-，避免吃掉运算符。
                       (or (not (memv (ch line k) '(#\+ #\-)))
                           (memv (ch line (sub1 k)) '(#\e #\E #\p #\P))))
                  (next (add1 k))
                  k)))
          (emit! 'number i end)
          (loop end #f #f #f #f #f #f #f)]

         [else
          (define ops '("<<=" ">>=" "..." "->" "++" "--" "==" "!=" "<=" ">="
                        "&&" "||" "<<" ">>" "+=" "-=" "*=" "/=" "%=" "&=" "|=" "^="))
          (define op
            (for/first ([op (in-list ops)]
                        #:when (and (>= (- n i) (string-length op))
                                    (string=? op (substring line i (+ i (string-length op))))))
              op))
          (define end (if op (+ i (string-length op)) (add1 i)))
          (emit! 'punct i end)
          (loop end #f #f #f #f #f #f #f)])])))

;;; ════════════════ 全文 ════════════════

(define (c-text-lines text)
  (string-split text "\n" #:trim? #f))

(define (c-tokenize text)
  (let loop ([lines (c-text-lines text)]
             [state c-empty-lex-state]
             [acc '()])
    (cond
      [(null? lines) (reverse acc)]
      [else
       (define-values (state* toks) (c-tokenize-line state (car lines)))
       (loop (cdr lines) state* (cons toks acc))])))

;; 光标列 -> token；光标在 token 尾部也算命中。
(define (c-line-token-at tokens col)
  (for/first ([t (in-list tokens)]
              #:when (and (<= (c-token-start t) col)
                          (or (< col (c-token-end t))
                              (= col (c-token-end t)))))
    t))

(define (c-word-kind? kind)
  (memq kind '(identifier keyword type constant)))

;; → string | #f
(define (c-identifier-at text line col)
  (define lines (c-text-lines text))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (length lines)))
     #f]
    [else
     (define toks (c-tokenize text))
     (define line-tokens (and (< line (length toks)) (list-ref toks line)))
     (define t (and line-tokens (c-line-token-at line-tokens col)))
     (and t
          (c-word-kind? (c-token-kind t))
          (let ([src (list-ref lines line)])
            (substring src (c-token-start t)
                       (min (c-token-end t) (string-length src)))))]))

;; 只取代码中的标识符；跳过注释 / 字符串 / 字符 / 预处理行。
(define (c-symbols-in-text text)
  (define lines (c-text-lines text))
  (define token-lines (c-tokenize text))
  (append*
   (for/list ([line (in-list lines)] [tokens (in-list token-lines)])
     (for/list ([t (in-list tokens)]
                #:when (c-word-kind? (c-token-kind t)))
       (substring line (c-token-start t)
                  (min (c-token-end t) (string-length line)))))))

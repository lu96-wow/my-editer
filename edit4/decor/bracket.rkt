#lang racket

;;; edit4/decor/bracket.rkt —— 括号装饰：嵌套深度底色 + 光标配对
;;;
;;; 装饰就是函数：path text cursor -> (listof (vectorof face))。
;;; 只对 Racket 源文件生效（不适用 → '()）。两层叠一起：
;;;   1) **嵌套深度背景**：每格按最内层括号对的 level 上 (palette-bg 'bracket level)，
;;;      字符串 / 行注释 / 块注释 / 字符字面量里的括号跳过；
;;;   2) **光标配对**：光标处（或紧邻）的括号与其配对括号上 'bracket-match，
;;;      叠在深度色之上（后层覆盖）。
;;;
;;; 深度先铺、配对后叠；face-compose 负责分层。纯函数，无状态。

(provide bracket-decor)

(require racket/string
         "kind.rkt"
         "../view/face.rkt")

;;; ---------- 括号匹配（纯） ----------

(define opens '(#\( #\[ #\{))
(define closes '(#\) #\] #\}))

(define (opener? c) (and c (memv c opens) #t))
(define (closer? c) (and c (memv c closes) #t))

(define (line-col->index text line col)
  (let loop ([i 0] [l 0])
    (cond
      [(= l line) (+ i col)]
      [(>= i (string-length text)) (string-length text)]
      [(char=? #\newline (string-ref text i)) (loop (add1 i) (add1 l))]
      [else (loop (add1 i) l)])))

(define (index->line-col text i)
  (let loop ([j 0] [l 0] [c 0])
    (cond
      [(>= j i) (cons l c)]
      [(>= j (string-length text)) (cons l c)]
      [(char=? #\newline (string-ref text j)) (loop (add1 j) (add1 l) 0)]
      [else (loop (add1 j) l (add1 c))])))

(define (bracket-at text line col)
  (define i (line-col->index text line col))
  (define n (string-length text))
  (define (bracket-idx j)
    (and (>= j 0) (< j n)
         (let ([c (string-ref text j)]) (and (or (opener? c) (closer? c)) j))))
  (or (bracket-idx i) (bracket-idx (sub1 i))))

(define (match-forward text i)
  (define n (string-length text))
  (define c (string-ref text i))
  (define close (case c [(#\() #\)] [(#\[) #\]] [(#\{) #\}] [else #f]))
  (let loop ([j (add1 i)] [depth 0])
    (cond
      [(>= j n) #f]
      [(eqv? (string-ref text j) c) (loop (add1 j) (add1 depth))]
      [(eqv? (string-ref text j) close) (if (zero? depth) j (loop (add1 j) (sub1 depth)))]
      [else (loop (add1 j) depth)])))

(define (match-backward text i)
  (define c (string-ref text i))
  (define open (case c [(#\)) #\(] [(#\]) #\[] [(#\}) #\{] [else #f]))
  (let loop ([j (sub1 i)] [depth 0])
    (cond
      [(< j 0) #f]
      [(eqv? (string-ref text j) c) (loop (sub1 j) (add1 depth))]
      [(eqv? (string-ref text j) open) (if (zero? depth) j (loop (sub1 j) (sub1 depth)))]
      [else (loop (sub1 j) depth)])))

;; 光标处（或紧邻）的括号及其配对括号位置 (listof (line . col))。
(define (match-brackets text line col)
  (define i (bracket-at text line col))
  (if (not i)
      '()
      (let* ([c (string-ref text i)]
             [partner (if (opener? c) (match-forward text i) (match-backward text i))])
        (if partner
            (list (index->line-col text i) (index->line-col text partner))
            '()))))

;;; ---------- 嵌套深度背景（纯，整篇） ----------

(define open->close (hash #\( #\) #\[ #\] #\{ #\}))
(define (open-ch? ch) (and (char? ch) (hash-has-key? open->close ch)))
(define (close-ch? ch) (and (char? ch) (memv ch '(#\) #\] #\}))))
(define (bracket-entry? e) (and (pair? e) (open-ch? (car e))))
(define (string-entry? e) (eq? (car e) 'string))
(define (block-entry? e) (eq? (car e) 'block))
(define (matches? e ch) (and (bracket-entry? e) (eqv? (hash-ref open->close (car e)) ch)))

;; 栈里括号层数（字符串 / 注释哨兵不算）。
(define (stack-level stack)
  (for/sum ([e (in-list stack)] #:when (bracket-entry? e)) 1))

;; 扫一整行；返回 (values (vectorof face)|#f 行尾栈)。
(define (bracket-line line ln stack syntax?)
  (define n (string-length line))
  (define vec (make-vector n #f))
  (define touched? #f)
  (define st stack)
  (define (emit! i lvl)
    (when (>= lvl 0)
      (set! touched? #t)
      (vector-set! vec i (palette-bg 'bracket lvl))))
  (define (emit-code! i) (emit! i (sub1 (stack-level st))))
  (let loop ([i 0])
    (cond
      [(>= i n) (values (and touched? vec) st)]
      [else
       (define ch (string-ref line i))
       (define top (and (pair? st) (car st)))
       (cond
         [(and syntax? top (string-entry? top))
          (cond
            [(char=? ch #\\)
             (emit-code! i)
             (when (< (add1 i) n) (emit-code! (add1 i)))
             (loop (min n (+ i 2)))]
            [(char=? ch #\") (emit-code! i) (set! st (cdr st)) (loop (add1 i))]
            [else (emit-code! i) (loop (add1 i))])]
         [(and syntax? top (block-entry? top))
          (cond
            [(and (< (add1 i) n) (char=? ch #\|) (char=? (string-ref line (add1 i)) #\#))
             (emit-code! i) (emit-code! (add1 i)) (set! st (cdr st)) (loop (+ i 2))]
            [(and (< (add1 i) n) (char=? ch #\#) (char=? (string-ref line (add1 i)) #\|))
             (emit-code! i) (emit-code! (add1 i))
             (set! st (cons (list 'block ln i) st)) (loop (+ i 2))]
            [else (emit-code! i) (loop (add1 i))])]
         [(and syntax? (char=? ch #\;))
          (for ([j (in-range i n)]) (emit-code! j))
          (values (and touched? vec) st)]
         [(and syntax? (char=? ch #\#) (< (add1 i) n) (char=? (string-ref line (add1 i)) #\|))
          (emit-code! i) (emit-code! (add1 i))
          (set! st (cons (list 'block ln i) st)) (loop (+ i 2))]
         [(and syntax? (char=? ch #\#) (< (add1 i) n) (char=? (string-ref line (add1 i)) #\\))
          (emit-code! i) (emit-code! (add1 i))
          (when (< (+ i 2) n) (emit-code! (+ i 2)))
          (loop (min n (+ i 3)))]
         [(and syntax? (char=? ch #\"))
          (emit-code! i) (set! st (cons (list 'string ln i) st)) (loop (add1 i))]
         [(open-ch? ch)
          (emit! i (stack-level st))
          (set! st (cons (list ch ln i (stack-level st)) st))
          (loop (add1 i))]
         [(close-ch? ch)
          (when (matches? top ch) (set! st (cdr st)))
          (emit! i (stack-level st))
          (loop (add1 i))]
         [else (emit-code! i) (loop (add1 i))])])))

;; 整篇 → 每行一个背景向量（face = (palette-bg 'bracket level) | #f）。
(define (bracket-depth-lines path text)
  (define syntax? (racket-file? path))
  (define lines (string-split text "\n"))
  (define st '())
  (for/list ([line (in-list lines)] [ln (in-naturals)])
    (define-values (vec st*) (bracket-line line ln st syntax?))
    (set! st st*)
    (or vec (make-vector (string-length line) #f))))

;;; ---------- 装饰（组合） ----------

;; 只对 Racket 源文件返回层，否则空。
(define (bracket-decor path text cursor)
  (cond
    [(not (racket-file? path)) '()]
    [else
     (define depth (bracket-depth-lines path text))
     (define pairs (if cursor (match-brackets text (car cursor) (cdr cursor)) '()))
     (for/list ([line (in-list (string-split text "\n"))] [ln (in-naturals)])
       (define vec (vector-copy (list-ref depth ln)))
       (for ([p (in-list pairs)] #:when (= ln (car p)))
         (define c (cdr p))
         (when (< c (vector-length vec))
           (vector-set! vec c (face-compose (vector-ref vec c) 'bracket-match))))
       vec)]))

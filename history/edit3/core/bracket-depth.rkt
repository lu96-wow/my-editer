#lang racket

;;; edit3/bracket-depth.rkt —— 括号嵌套深度背景（纯，整篇）
;;;
;;; 每行行首维护一个「括号栈」；每格的背景 = 最内层包围它的括号对的 level（最外层 = 0），
;;; 不在任何对里 = #f。Racket 文件按词法跳过字符串 "…"、行注释 ;…、块注释 #| … |#（可嵌套）、
;;; 字符字面量 #\x 里的括号；跨行字符串 / 注释用哨兵压栈保留。
;;;
;;; 移植自 edit/plugins/highlight/bracket-pair.rkt 的**全量**部分（edit/ 的按行增量
;;; 是为其 line-scan 层服务的；edit3 的 face 插件协议是整篇重扫，故只留全量纯算法）。

(provide bracket-depth-lines)

(require racket/string
         "face.rkt"
         "kind.rkt")

;;; ---------- 记号 ----------

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

;;; ---------- 一行 → 背景向量 ----------

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

;;; ---------- 全量 ----------

;; 整篇 → 每行一个背景向量（face = (palette-bg 'bracket level) | #f）。
(define (bracket-depth-lines path text)
  (define syntax? (racket-file? path))
  (define lines (string-split text "\n"))
  (define st '())
  (for/list ([line (in-list lines)] [ln (in-naturals)])
    (define-values (vec st*) (bracket-line line ln st syntax?))
    (set! st st*)
    (or vec (make-vector (string-length line) #f))))

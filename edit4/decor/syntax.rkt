#lang racket

;;; edit4/decor/syntax.rkt —— 语法（关键字/字符串/注释/数字）高亮装饰
;;;
;;; 一个装饰就是一个函数：path text cursor -> (listof (vectorof face))。
;;; 只对 Racket 源文件生效（不适用 → 返回 '()）。跨行块注释 / 字符串用行间状态。
;;; 关键字按分组取主题 'keyword 调色板。

(provide syntax-decor)

(require racket/string
         "lex.rkt"
         "../view/face.rkt"
         "../config/syntax.rkt")

(define category-index
  (for/hash ([c (in-list keyword-category-order)] [i (in-naturals)]) (values c i)))

(define (keyword-face w)
  (define cat (hash-ref keyword-categories w #f))
  (and cat (palette-color 'keyword (hash-ref category-index cat))))

;; 跨行状态 = (block-depth . in-string?)
(define (scan-line st line)
  (define n (string-length line))
  (define faces (make-vector n #f))
  (define (paint! a b f) (for ([i (in-range a (min b n))]) (vector-set! faces i f)))
  (let loop ([i 0] [block (car st)] [in-str? (cdr st)])
    (cond
      [(>= i n) (values (cons block in-str?) faces)]
      [(and (not in-str?) (char=? #\# (string-ref line i))
            (< (add1 i) n) (char=? #\| (string-ref line (add1 i))))
       (paint! i (+ i 2) 'syntax-comment) (loop (+ i 2) (add1 block) in-str?)]
      [(and (not in-str?) (positive? block)
            (char=? #\| (string-ref line i))
            (< (add1 i) n) (char=? #\# (string-ref line (add1 i))))
       (paint! i (+ i 2) 'syntax-comment) (loop (+ i 2) (sub1 block) in-str?)]
      [(positive? block) (paint! i (add1 i) 'syntax-comment) (loop (add1 i) block in-str?)]
      [(char=? #\" (string-ref line i))
       (paint! i (add1 i) 'syntax-string) (loop (add1 i) block (not in-str?))]
      [in-str?
       (cond [(and (char=? #\\ (string-ref line i)) (< (add1 i) n))
              (paint! i (+ i 2) 'syntax-string) (loop (+ i 2) block #t)]
             [else (paint! i (add1 i) 'syntax-string) (loop (add1 i) block #t)])]
      [(char=? #\; (string-ref line i)) (paint! i n 'syntax-comment) (values (cons block #f) faces)]
      [(and (char=? #\# (string-ref line i)) (< (add1 i) n) (char=? #\\ (string-ref line (add1 i))))
       (paint! i (min n (+ i 3)) 'syntax-string) (loop (min n (+ i 3)) block #f)]
      [(char-numeric? (string-ref line i))
       (define end (let next ([j (add1 i)])
                     (if (and (< j n) (or (char-numeric? (string-ref line j))
                                          (char=? #\. (string-ref line j))))
                         (next (add1 j)) j)))
       (paint! i end 'syntax-number) (loop end block #f)]
      [else (loop (add1 i) block #f)])))

(define (scan-lines text)
  (define lines (string-split text "\n"))
  (define-values (_st rev)
    (for/fold ([st (cons 0 #f)] [acc '()]) ([line (in-list lines)])
      (define-values (st2 vec) (scan-line st line))
      (for ([m (in-list (line-tokens line))])
        (define w (substring line (car m) (cdr m)))
        (define f (keyword-face w))
        (when f (for ([i (in-range (car m) (cdr m))])
                  (unless (vector-ref vec i) (vector-set! vec i f)))))
      (values st2 (cons vec acc))))
  (reverse rev))

;; 装饰：按行扫描；“只对哪些文件生效”由插件包的 #:applies? 声明（不再写在算法里）。
(define (syntax-decor _path text _cursor)
  (scan-lines text))

#lang racket

;;; edit4/decor/syntax.rkt —— 语法（关键字/字符串/注释/数字）高亮装饰（增量）
;;;
;;; decor：open 整篇扫；change 从首个脏行带**跨行状态**（块注释深度 / 是否在字符串里）
;;; 重扫到状态收敛（见 dirty.rkt 的 stateful-advance）。
;;; 只对 Racket 源文件生效由插件包 #:applies? 声明。

(provide syntax-decor syntax-line)

(require racket/string
         "lex.rkt"
         "protocol.rkt"
         "dirty.rkt"
         "../view/face.rkt"
         "../config/syntax.rkt"
         (only-in "../../core/text/base/track.rkt" track-of-list))

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

;; 一行：先按词法状态涂字符串/注释/数字，再给词法未被占用的 token 叠关键字色。
(define (syntax-line st line)
  (define-values (st2 vec) (scan-line st line))
  (for ([m (in-list (line-tokens line))])
    (define f (keyword-face (substring line (car m) (cdr m))))
    (when f
      (for ([i (in-range (car m) (cdr m))])
        (unless (vector-ref vec i) (vector-set! vec i f)))))
  (values st2 vec))

(define syntax-decor
  (decor
   (lambda (_path text)
     (define-values (states layer _st)
       (for/fold ([ss '()] [ls '()] [st (cons 0 #f)])
                 ([line (in-list (track->lines text))])
         (define-values (st2 vec) (syntax-line st line))
         (values (cons st2 ss) (cons vec ls) st2)))
     (values (track-of-list (reverse states))
             (track-of-list (reverse layer))))
   (lambda (state layer ctx)
     (define changes (face-ctx-changes ctx))
     (cond
       [(null? changes) (values state layer (dirty-lines '()))]
       [else
        (stateful-advance state layer (face-ctx-new-text ctx) changes
                          (lambda (st _ln line) (syntax-line st line))
                          (cons 0 #f))]))))

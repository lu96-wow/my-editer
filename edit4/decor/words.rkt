#lang racket

;;; edit4/decor/words.rkt —— 光标所在词高亮装饰
;;;
;;; 装饰就是函数：path text cursor -> (listof (vectorof face))。

(provide words-decor)

(require racket/string
         "lex.rkt")

(define (words-decor _path text cursor)
  (define lines (string-split text "\n"))
  (define cl (car cursor))
  (define cc (cdr cursor))
  (for/list ([line (in-list lines)] [i (in-naturals)])
    (define n (string-length line))
    (define vec (make-vector n #f))
    (when (= i cl)
      (for ([m (in-list (line-tokens line))])
        (when (and (<= (car m) cc) (<= cc (cdr m)))
          (for ([j (in-range (car m) (cdr m))]) (vector-set! vec j 'word-mark)))))
    vec))

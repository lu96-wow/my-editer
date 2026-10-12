#lang racket

;;; edit4/decor/words.rkt —— 光标所在词高亮装饰
;;;
;;; 装饰就是函数：path text cursor -> (listof (vectorof face))。

(provide words-decor)

(require racket/string
         "lex.rkt")

(define (words-decor _path text cursor)
  (for/list ([line (in-list (string-split text "\n"))] [i (in-naturals)])
    (define vec (make-vector (string-length line) #f))
    (when (and cursor (= i (car cursor)))
      (define cc (cdr cursor))
      (for ([m (in-list (line-tokens line))])
        (when (and (<= (car m) cc) (<= cc (cdr m)))
          (for ([j (in-range (car m) (cdr m))]) (vector-set! vec j 'word-mark)))))
    vec))

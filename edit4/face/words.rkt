#lang racket

;;; edit4/face/words.rkt —— 光标所在词高亮 face 插件

(provide words-plugin)

(require racket/string
         "lex.rkt"
         "../view/face-plugin.rkt")

(define (words-scan _path text cursor)
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

(define words-plugin
  (face-plugin 'words (lambda (_path _text) #t) words-scan))

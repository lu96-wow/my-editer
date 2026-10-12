#lang racket

;;; edit4/decor/word-color.rkt —— 同词着色（参考 edit1 的 plugins/highlight/words.rkt）
;;;
;;; 每个标识符的色 = djb2(词名) % word-color-count → palette-color 'word。
;;; 同词同色、跨行跨文件、跨会话稳定（纯函数，不依赖光标 / 会话状态）。
;;; 关键字等由 syntax 装饰在前景上覆盖，于是「词色」只是默认前景。
;;;
;;; 装饰就是函数：path text cursor -> (listof (vectorof face))。

(provide word-color-decor word-face)

(require racket/string
         "lex.rkt"
         "../view/face.rkt"
         "../config/words.rkt")

;; djb2：稳定散列（不依赖 equal-hash-code 的随机性，跨会话一致）。
(define (word-hash w)
  (for/fold ([h 5381]) ([c (in-string w)])
    (bitwise-and (+ (* h 33) (char->integer c)) #xFFFFFFFF)))

(define (word-face w)
  (palette-color 'word (modulo (word-hash w) (max 1 word-color-count))))

(define (word-color-decor _path text _cursor)
  (for/list ([line (in-list (string-split text "\n"))])
    (define vec (make-vector (string-length line) #f))
    (for ([m (in-list (line-tokens line))])
      (define f (word-face (substring line (car m) (cdr m))))
      (for ([i (in-range (car m) (cdr m))]) (vector-set! vec i f)))
    vec))

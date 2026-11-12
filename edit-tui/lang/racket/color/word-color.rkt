#lang racket

;;; edit-tui/lang/racket/word-color.rkt —— 同词着色（纯）
;;;
;;; 每个标识符的色 = djb2(词名) % word-color-count。
;;; API 返回稳定整数 / 语义角色，不返回 face；主题再映射到实际颜色。
;;; 词法切分来自 lex.rkt，与语法高亮共用。

(provide word-color-count
         word-color-index
         word-color-role
         word-color-line
         word-color-text)

(require racket/string
         "../base/lex.rkt")

(define word-color-count 12)

;; djb2：稳定散列（不依赖 equal-hash-code 的随机性，跨会话一致）。
(define (word-hash w)
  (for/fold ([h 5381]) ([c (in-string w)])
    (bitwise-and (+ (* h 33) (char->integer c)) #xFFFFFFFF)))

(define (word-color-index word)
  (modulo (word-hash word) (max 1 word-color-count)))

(define (word-color-role word)
  (string->symbol (format "word-color-~a" (word-color-index word))))

;; 一行 token + 行文本 -> (vector role|#f)
(define (word-color-line line-tokens line)
  (define n (string-length line))
  (define roles (make-vector n #f))
  (for ([t (in-list line-tokens)]
        #:when (eq? (token-kind t) 'symbol))
    (define word (substring line (token-start t) (min (token-end t) n)))
    (define role (word-color-role word))
    (for ([i (in-range (token-start t) (min (token-end t) n))])
      (vector-set! roles i role)))
  roles)

;; 整篇 -> (listof (vectorof role|#f))
(define (word-color-text text)
  (define lines (string-split text "\n" #:trim? #f))
  (define token-lines (tokenize text))
  (for/list ([line (in-list lines)] [tokens (in-list token-lines)])
    (word-color-line tokens line)))

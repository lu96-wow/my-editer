#lang racket

;;; edit-tui/lang/racket/highlight.rkt —— Racket 关键字 / 字符串 / 注释 / 数字高亮（纯）
;;;
;;; API 只返回“语义角色”（symbol），不返回 face：
;;;   'syntax-comment / 'syntax-string / 'syntax-number
;;;   'syntax-keyword-def / 'syntax-keyword-control / ...
;;;
;;; 这样 Racket 语言层不知道主题；编辑器把角色映射成 face 即可。
;;; 真正的 token 切分在 lex.rkt，补全 / 同词着色共用。

(provide highlight-line
         highlight-text
         highlight-role
         keyword-role
         lexical-role)

(require racket/string
         "../base/lex.rkt"
         "../base/keywords.rkt")

(define (keyword-role word)
  (define cat (keyword-category word))
  (and cat
       (string->symbol (format "syntax-keyword-~a" cat))))

(define (lexical-role kind)
  (case kind
    [(comment) 'syntax-comment]
    [(string char) 'syntax-string]
    [(number) 'syntax-number]
    [else #f]))

;; 一行 token + 行文本 -> (vector role|#f)
;; 词法类别优先（注释 / 字符串 / 数字）；其余 symbol 再看关键字表。
(define (highlight-line line-tokens line)
  (define n (string-length line))
  (define roles (make-vector n #f))
  (for ([t (in-list line-tokens)])
    (define role
      (or (lexical-role (token-kind t))
          (and (eq? (token-kind t) 'symbol)
               (keyword-role (substring line
                                         (token-start t)
                                         (min (token-end t) n))))))
    (when role
      (for ([i (in-range (token-start t) (min (token-end t) n))])
        (vector-set! roles i role))))
  roles)

;; 整篇 -> (listof (vectorof role|#f))，每行一个向量。
(define (highlight-text text)
  (define lines (string-split text "\n" #:trim? #f))
  (define token-lines (tokenize text))
  (for/list ([line (in-list lines)] [tokens (in-list token-lines)])
    (highlight-line tokens line)))

;; 供单测 / 增量阶段使用的便捷查询。
(define (highlight-role text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (length lines)))
     #f]
    [else
     (define line* (list-ref lines line))
     (define roles (list-ref (highlight-text text) line))
     (and (< col (vector-length roles))
          (vector-ref roles col))]))

#lang racket

;;; edit-tui/lang/c/color/highlight.rkt —— C 语法高亮 role（纯）
;;;
;;; role 是语义名，主题由 host 决定：
;;;   syntax-comment / syntax-string / syntax-number
;;;   syntax-preprocessor / syntax-keyword / syntax-type
;;;   syntax-function / syntax-constant

(require racket/string
         "../base/lex.rkt")

(provide c-highlight-line
         c-highlight-text
         c-highlight-role)

(define (token-text line t)
  (substring line (c-token-start t)
             (min (c-token-end t) (string-length line))))

(define (next-non-ws tokens)
  (for/first ([t (in-list tokens)]
              #:unless (memq (c-token-kind t) '(whitespace comment)))
    t))

(define (punct-open? line t)
  (and t
       (< (c-token-start t) (string-length line))
       (char=? (string-ref line (c-token-start t)) #\()))

(define (role-for-token line tokens t)
  (case (c-token-kind t)
    [(comment) 'syntax-comment]
    [(string char) 'syntax-string]
    [(number) 'syntax-number]
    [(preprocessor) 'syntax-preprocessor]
    [(keyword) 'syntax-keyword]
    [(type) 'syntax-type]
    [(constant) 'syntax-constant]
    [(identifier)
     (define word (token-text line t))
     ;; 当前 token 之后、下一个非空白 token 是 '(' -> 函数调用 / 定义名。
     (define rest
       (for/list ([x (in-list tokens)]
                  #:when (>= (c-token-start x) (c-token-end t)))
         x))
     (define next (next-non-ws rest))
     (cond
       [(and next (punct-open? line next)) 'syntax-function]
       [(regexp-match? #rx"^[A-Z_][A-Z0-9_]*$" word) 'syntax-constant]
       [else #f])]
    [else #f]))

;; 一行 -> (vector role|#f)
(define (c-highlight-line tokens line)
  (define n (string-length line))
  (define roles (make-vector n #f))
  (for ([t (in-list tokens)])
    (define role (role-for-token line tokens t))
    (when role
      (for ([i (in-range (max 0 (c-token-start t))
                         (min n (c-token-end t)))])
        (vector-set! roles i role))))
  roles)

(define (c-highlight-text text)
  (define lines (c-text-lines text))
  (define token-lines (c-tokenize text))
  (for/list ([line (in-list lines)] [tokens (in-list token-lines)])
    (c-highlight-line tokens line)))

(define (c-highlight-role text line col)
  (define lines (c-text-lines text))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (length lines)))
     #f]
    [else
     (define roles (list-ref (c-highlight-text text) line))
     (and (< col (vector-length roles)) (vector-ref roles col))]))

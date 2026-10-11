#lang racket

;;; edit3/plugins/brackets.rkt —— 匹配括号高亮（光标驱动）
;;;
;;; face 插件：光标处（或紧邻）的括号与其配对括号加 'bracket-match 背景。

(require racket/string
         "../core/extension.rkt")

(provide bracket-spec)

(define (brackets-scan _path text cursor)
  (define lines (string-split text "\n"))
  (define pairs (if cursor (match-brackets text (car cursor) (cdr cursor)) '()))
  (for/list ([line (in-list lines)] [ln (in-naturals)])
    (define vec (make-vector (string-length line) #f))
    (for ([p (in-list pairs)] #:when (= ln (car p)))
      (vector-set! vec (cdr p) 'bracket-match))
    vec))

(define bracket-spec
  (make-plugin #:name 'brackets
               #:faces (list (face-plugin 'brackets racket-applies? brackets-scan))))

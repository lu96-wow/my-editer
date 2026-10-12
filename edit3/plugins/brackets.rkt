#lang racket

;;; edit3/plugins/brackets.rkt —— 括号高亮（深度背景 + 光标配对）
;;;
;;; face 插件（只对 Racket 文件）：两件事叠在一起：
;;;   1) **嵌套深度背景**：每格按最内层括号对的 level 上 (palette-bg 'bracket level)，
;;;      字符串 / 注释 / 字符字面量里不上色（core/bracket-depth.rkt，移植自 edit/）；
;;;   2) **光标配对**：光标处（或紧邻）的括号与其配对括号上 'bracket-match 背景，
;;;      叠在深度色之上覆盖。
;;; 一个插件、一个通道：深度先铺，配对后叠（后层覆盖前层）。

(require racket/string
         "../core/extension.rkt")

(provide bracket-spec)

(define (brackets-scan path text cursor)
  (define depth (bracket-depth-lines path text))
  (define pairs (if cursor (match-brackets text (car cursor) (cdr cursor)) '()))
  (for/list ([line (in-list (string-split text "\n"))] [ln (in-naturals)])
    (define vec (if (< ln (length depth))
                    (vector-copy (list-ref depth ln))
                    (make-vector (string-length line) #f)))
    (for ([p (in-list pairs)] #:when (= ln (car p)))
      (define c (cdr p))
      (when (< c (vector-length vec))
        (vector-set! vec c (face-compose (vector-ref vec c) 'bracket-match))))
    vec))

(define bracket-spec
  (make-plugin #:name 'brackets
               #:faces (list (face-plugin 'brackets racket-applies? brackets-scan))))

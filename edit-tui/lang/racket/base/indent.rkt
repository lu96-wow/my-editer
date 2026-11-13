#lang racket

;;; edit-tui/lang/racket/base/indent.rkt —— Enter 后的行对齐（纯）
;;;
;;; Enter 不再做 Racket 语法缩进，只复制当前行的前导空白：
;;;   · 同层并列项直接对齐；
;;;   · 需要更深缩进时自己按 Tab；
;;;   · 空行 / 无前导空白时返回空串。
;;;
;;; 保留 col 参数以维持现有调用形状；对齐只取决于当前行。

(require racket/string)

(provide racket-indent-for-newline)

(define (leading-whitespace s)
  (define m (regexp-match #rx"^[ \t]*" s))
  (if m (car m) ""))

(define (racket-indent-for-newline text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (length lines)))
     ""]
    [else
     (define line-text (list-ref lines line))
     (leading-whitespace line-text)]))

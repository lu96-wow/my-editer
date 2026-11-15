#lang racket

;;; edit-tui/lang/c/base/indent.rkt —— C Enter 缩进（首版轻量）
;;;
;;; 只做“复制当前行前导空白 + 上一条有效行以 { 结尾时加一级”。
;;; 不做完整语法分析；不会假装是 clang-format。

(require racket/string)

(provide c-indent-for-newline
         c-indent-width)

(define c-indent-width 4)

(define (leading-whitespace s)
  (let loop ([i 0])
    (if (and (< i (string-length s))
             (or (char=? (string-ref s i) #\space)
                 (char=? (string-ref s i) #\tab)))
        (loop (add1 i))
        (substring s 0 i))))

;; text / line / col -> 插入 '\n' 后要追加的缩进字符串
;;
;; 首版只做“和当前行前导空白一致”，不猜测块层级。
;; 用户明确要求 Enter 后与当前行对齐；更聪明的 block indent 留给以后配置。
(define (c-indent-for-newline text line _col)
  (define lines (string-split text "\n" #:trim? #f))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (length lines)))
     ""]
    [else (leading-whitespace (list-ref lines line))]))

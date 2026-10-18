#lang racket

;;; plugins/highlight/depth.rkt —— 括号深度扫描（纯）：只产出**背景** fills
;;;
;;; layer  : plugins/highlight
;;; effect : 无（纯：文本 -> fills）
;;;
;;; 按括号嵌套深度给每行一段底色：深度 1 / 2 / 3 分别用不同背景名。
;;; 它与语法高亮（前景）是**两个独立的层**：同一格上前景来自 lex，背景来自这里，
;;; 合成由 model/face-layer.rkt 按层序完成 —— 谁也不会覆盖谁。
;;;
;;; 暂定：只认 `(` / `[` / `{` 与 `)` / `]` / `}`，不跳过字符串 / 注释（与 lex 独立）。

(provide depth-fills
         depth-face-of)

(define max-depth 3)

;; 深度 -> 背景 face 名（超出上限按上限）
(define (depth-face-of depth)
  (define d (max 1 (min depth max-depth)))
  (case d
    [(1) 'bg-depth-1]
    [(2) 'bg-depth-2]
    [else 'bg-depth-3]))

(define (open? c) (memv c '(#\( #\[ #\{)))
(define (close? c) (memv c '(#\) #\] #\})))

;; 文本 -> fills（(list l0 c0 l1 c1 face)）；同一行内连续同深度合成一段。
(define (depth-fills text)
  (define lines (string-split text "\n"))
  (for/fold ([acc '()] [depth 0] #:result acc) ([line (in-list lines)] [lno (in-naturals)])
    (define n (string-length line))
    (define (emit! a b d)                        ; [a,b) 这一段用深度 d 的底色
      (when (< a b)
        (set! acc (cons (list lno a lno b (depth-face-of d)) acc))))
    (let loop ([i 0] [d depth] [start 0])
      (cond
        [(>= i n)
         (emit! start n d)
         (values acc d)]
        [(open? (string-ref line i))
         (emit! start i d)                       ; 括号之前用当前深度
         (emit! i (add1 i) (add1 d))             ; 括号本身用进入后的深度
         (loop (add1 i) (add1 d) (add1 i))]
        [(close? (string-ref line i))
         (define d* (max 0 (sub1 d)))
         (emit! start i d)
         (emit! i (add1 i) d)
         (loop (add1 i) d* (add1 i))]
        [else (loop (add1 i) d start)]))))

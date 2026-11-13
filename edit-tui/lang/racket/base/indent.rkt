#lang racket

;;; edit-tui/lang/racket/base/indent.rkt —— Racket 新行缩进（纯）
;;;
;;; 只做“在 line/col 处按 Enter 后，新行应该带多少前导空格”。
;;; 规则是保守的 Racket 风格近似：
;;;   · 当前行 prefix 里还有未闭合的左括号 -> 当前行缩进 + 2
;;;   · 否则若仍在某个未闭合括号内 -> 最内层左括号列 + 2
;;;   · 否则回到 0
;;;
;;; 字符串 / 注释里的括号由 lex.rkt 的 token 过滤，不参与栈。

(provide racket-indent-for-newline)

(require racket/string
         "lex.rkt")

(define (open-bracket? ch)
  (and (char? ch) (memv ch '(#\( #\[ #\{)) #t))

(define (close-bracket? ch)
  (and (char? ch) (memv ch '(#\) #\] #\})) #t))

(define (matching-close open)
  (case open
    [(#\() #\)]
    [(#\[) #\]]
    [(#\{) #\}]
    [else #f]))

(define (matches? open close)
  (eqv? (matching-close open) close))

;; stack : (listof (cons open-char open-column))，栈顶在前。
;; lex.rkt 会合并相邻 paren token（例如 "])"），所以这里逐字符处理。
(define (process-token stack line token)
  (cond
    [(not (eq? (token-kind token) 'paren)) stack]
    [else
     (let loop ([i (token-start token)] [stack stack])
       (cond
         [(or (>= i (token-end token))
              (>= i (string-length line)))
          stack]
         [else
          (define ch (string-ref line i))
          (loop (add1 i)
                (cond
                  [(open-bracket? ch) (cons (cons ch i) stack)]
                  [(close-bracket? ch)
                   (if (and (pair? stack) (matches? (caar stack) ch))
                       (cdr stack)
                       stack)]
                  [else stack]))]))]))

(define (process-tokens stack line tokens)
  (for/fold ([stack stack]) ([t (in-list tokens)]
                             #:when (eq? (token-kind t) 'paren))
    (process-token stack line t)))

(define (process-prefix-tokens stack line tokens col)
  (for/fold ([stack stack]) ([t (in-list tokens)]
                             #:when (and (eq? (token-kind t) 'paren)
                                         (<= (token-end t) col)))
    (process-token stack line t)))

(define (leading-space-count s)
  (let loop ([i 0])
    (cond
      [(>= i (string-length s)) i]
      [(char-whitespace? (string-ref s i)) (loop (add1 i))]
      [else i])))

(define (racket-indent-for-newline text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (cond
    [(or (not (exact-nonnegative-integer? line))
         (>= line (length lines)))
     ""]
    [else
     (define token-lines (tokenize text))
     (define start-stack
       (let loop ([ln 0] [stack '()])
         (cond
           [(>= ln line) stack]
           [else
            (loop (add1 ln)
                  (process-tokens stack
                                  (list-ref lines ln)
                                  (list-ref token-lines ln)))])))
     (define line-text (list-ref lines line))
     (define prefix (substring line-text 0 (min col (string-length line-text))))
     (define leading (leading-space-count prefix))
     (define after
       (process-prefix-tokens start-stack line-text
                              (list-ref token-lines line)
                              (min col (string-length line-text))))
     (define indent
       (cond
         ;; prefix 里又打开了括号：往里缩一层。
         [(> (length after) (length start-stack)) (+ leading 2)]
         ;; 仍在括号内：对齐到最内层左括号后一格。
         [(pair? after) (+ (cdar after) 2)]
         [else 0]))
     (make-string (max 0 indent) #\space)]))

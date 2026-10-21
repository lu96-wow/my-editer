#lang racket

;;; edit-tui/lang/racket/color/bracket.rkt —— 括号嵌套深度背景（纯）
;;;
;;; 只产出语义 role，不决定实际颜色：
;;;   bracket-depth-0 .. bracket-depth-7
;;;
;;; 深度定义与 edit4 一致：
;;;   · 最外层括号对及其内容用 depth 0，往内依次 +1；
;;;   · 不在任何括号对里的字符没有背景（#f）；
;;;   · 字符串 / 注释里的括号不改变栈（lex.rkt 已经把它们切成 string/comment token）；
;;;   · 未匹配的右括号不弹栈，也不额外标记。
;;;
;;; 跨行状态只是一个括号栈。栈元素是左括号字符；token 流由 lex.rkt 提供，
;;; 所以这里不再重复处理字符串 / 块注释的跨行状态。

(provide bracket-color-count
         bracket-depth-role
         bracket-scan-line
         bracket-depth-text)

(require racket/string
         "../base/lex.rkt")

(define bracket-color-count 8)

(define (bracket-depth-role level)
  (string->symbol
   (format "bracket-depth-~a"
           (modulo (max 0 level) bracket-color-count))))

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

(define (paint! vec start end level)
  (when (and (>= level 0) (< start end))
    (define role (bracket-depth-role level))
    (for ([i (in-range start (min end (vector-length vec)))])
      (vector-set! vec i role))))

;; token 流 + 行文本 + 入栈 -> (values 出栈 行 role 向量)
(define (bracket-scan-line tokens line stack)
  (define n (string-length line))
  (define roles (make-vector n #f))
  (define (code-level st) (sub1 (length st)))

  (let loop ([ts tokens] [st stack])
    (cond
      [(null? ts) (values st roles)]
      [else
       (define t (car ts))
       (define a (token-start t))
       (define b (min (token-end t) n))
       (define kind (token-kind t))
       (case kind
         [(comment string)
          ;; 字符串 / 注释仍在当前括号环境里，只是不影响括号栈。
          (paint! roles a b (code-level st))
          (loop (cdr ts) st)]
         [(paren)
          ;; lex.rkt 会合并相邻同类 token，所以 "((" 是一个 paren token；
          ;; 这里必须逐字符处理括号栈。
          (let loop-chars ([i a] [st st])
            (cond
              [(>= i b) (loop (cdr ts) st)]
              [else
               (define ch (string-ref line i))
               (cond
                 [(open-bracket? ch)
                  ;; 左括号本身属于外层深度；内容从下一层开始。
                  (paint! roles i (add1 i) (length st))
                  (loop-chars (add1 i) (cons ch st))]
                 [(close-bracket? ch)
                  (define st* (if (and (pair? st) (matches? (car st) ch))
                                   (cdr st)
                                   st))
                  ;; 右括号与它匹配的左括号同层。
                  (paint! roles i (add1 i) (length st*))
                  (loop-chars (add1 i) st*)]
                 [else
                  (paint! roles i (add1 i) (code-level st))
                  (loop-chars (add1 i) st)])]))]
         [else
          (paint! roles a b (code-level st))
          (loop (cdr ts) st)])])))

;; 整篇 -> (listof (vectorof role|#f))，每行一个向量。
(define (bracket-depth-text text)
  (define lines (string-split text "\n" #:trim? #f))
  (define token-lines (tokenize text))
  (let loop ([lines lines] [tokens token-lines] [stack '()] [acc '()])
    (cond
      [(null? lines) (reverse acc)]
      [else
       (define-values (stack* roles)
         (bracket-scan-line (car tokens) (car lines) stack))
       (loop (cdr lines) (cdr tokens) stack* (cons roles acc))])))

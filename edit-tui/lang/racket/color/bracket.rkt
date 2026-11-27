#lang racket

;;; edit-tui/lang/racket/color/bracket.rkt —— 括号嵌套深度背景（纯）
;;;
;;; 只产出语义 role，不决定实际颜色：
;;;   bracket-depth-N          普通内容（括号对内部）
;;;   bracket-depth-N-bracket  括号字符本身：背景仍是 N，前景由 N 的背景色提亮
;;;   bracket-depth-N-match    光标所在括号 + 它的配对括号：同背景，前景更亮
;;;
;;; 深度定义与 edit4 一致：
;;;   · 最外层括号对及其内容用 depth 0，往内依次 +1；
;;;   · 不在任何括号对里的字符没有背景（#f）；
;;;   · 字符串 / 注释里的括号不改变栈（lex.rkt 已经把它们切成 string/comment token）；
;;;   · 未匹配的右括号不弹栈，也不额外标记。
;;;
;;; 跨行状态只是一个括号栈。栈元素是左括号字符；token 流由 lex.rkt 提供，
;;; 所以这里不再重复处理字符串 / 块注释的跨行状态。
;;;
;;; bracket-pair-map 用同一个 token 流做严格配对：只有栈顶且类型相同的左右括号
;;; 才算一对；字符串 / 注释里的括号不参与，未匹配括号不会产生配对。

(provide bracket-color-count
         bracket-depth-role
         bracket-bracket-role
         bracket-char-role?
         bracket-match-role-of
         bracket-glyph-bg-role
         bracket-content-role
         bracket-scan-token!
         bracket-scan-line
         bracket-depth-text
         bracket-pair-map)

(require racket/string
         "../base/lex.rkt")

(define bracket-color-count 8)

;; 深度只有 8 层：role 是固定的小集合。预先建好符号表，
;; 避免每个字符都 format + string->symbol + regexp（大文件首屏 / 每次重算 face 的热点）。
(define depth-role-table
  (for/vector ([i (in-range bracket-color-count)])
    (string->symbol (format "bracket-depth-~a" i))))
(define bracket-role-table
  (for/vector ([i (in-range bracket-color-count)])
    (string->symbol (format "bracket-depth-~a-bracket" i))))
(define match-role-table
  (for/vector ([i (in-range bracket-color-count)])
    (string->symbol (format "bracket-depth-~a-match" i))))

;; role -> 同层内容背景 role / match role；以及“是否是括号字形 role”。
(define glyph-bg-role-table
  (for*/hash ([i (in-range bracket-color-count)]
              [r (in-list (list (vector-ref bracket-role-table i)
                                (vector-ref match-role-table i)))])
    (values r (vector-ref depth-role-table i))))
(define bracket-role->match-table
  (for/hash ([i (in-range bracket-color-count)])
    (values (vector-ref bracket-role-table i)
            (vector-ref match-role-table i))))

(define (depth-index level) (modulo (max 0 level) bracket-color-count))
(define (bracket-depth-role level) (vector-ref depth-role-table (depth-index level)))
(define (bracket-bracket-role level) (vector-ref bracket-role-table (depth-index level)))

(define (bracket-match-role-of role)
  (and role (hash-ref bracket-role->match-table role #f)))

(define (bracket-char-role? role)
  (and role (hash-ref bracket-role->match-table role #f) #t))

;; 括号字符 / 配对标记 role -> 同层内容背景 role。
(define (bracket-glyph-bg-role role)
  (and role (hash-ref glyph-bg-role-table role #f)))

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

(define (paint-bracket! vec i level)
  (when (and (>= level 0) (< i (vector-length vec)))
    (vector-set! vec i (bracket-bracket-role level))))

(define (code-level st) (sub1 (length st)))

;; 当前括号环境里的“内容” role；栈空 → #f（不在任何括号对里）。
(define (bracket-content-role stack)
  (define level (code-level stack))
  (and (>= level 0) (bracket-depth-role level)))

;; 单个 token：写入 bracket role 向量，返回新的括号栈。
;; 上层把 tokenize / syntax / word 合成一遍时也用它，避免再遍历 token。
(define (bracket-scan-token! roles t line stack)
  (define n (string-length line))
  (define a (token-start t))
  (define b (min (token-end t) n))
  (define kind (token-kind t))
  (case kind
    [(comment string)
     ;; 字符串 / 注释仍在当前括号环境里，只是不影响括号栈。
     (paint! roles a b (code-level stack))
     stack]
    [(paren)
     ;; lex.rkt 会合并相邻同类 token，所以 "((" 是一个 paren token；
     ;; 这里必须逐字符处理括号栈。
     (let loop-chars ([i a] [st stack])
       (cond
         [(>= i b) st]
         [else
          (define ch (string-ref line i))
          (cond
            [(open-bracket? ch)
             ;; 左括号本身属于外层深度；内容从下一层开始。
             (paint-bracket! roles i (length st))
             (loop-chars (add1 i) (cons ch st))]
            [(close-bracket? ch)
             (define st* (if (and (pair? st) (matches? (car st) ch))
                              (cdr st)
                              st))
             ;; 右括号与它匹配的左括号同层。
             (paint-bracket! roles i (length st*))
             (loop-chars (add1 i) st*)]
            [else
             (paint! roles i (add1 i) (code-level st))
             (loop-chars (add1 i) st)])]))]
    [else
     (paint! roles a b (code-level stack))
     stack]))

;; token 流 + 行文本 + 入栈 -> (values 出栈 行 role 向量)
(define (bracket-scan-line tokens line stack)
  (define n (string-length line))
  (define roles (make-vector n #f))
  (define stack*
    (for/fold ([st stack]) ([t (in-list tokens)])
      (bracket-scan-token! roles t line st)))
  (values stack* roles))

;; 整篇 -> (listof (vectorof role|#f))，每行一个向量。
(define (bracket-depth-text text)
  (define lines (split-lines text))
  (define token-lines (tokenize text))
  (let loop ([lines lines] [tokens token-lines] [stack '()] [acc '()])
    (cond
      [(null? lines) (reverse acc)]
      [else
       (define-values (stack* roles)
         (bracket-scan-line (car tokens) (car lines) stack))
       (loop (cdr lines) (cdr tokens) stack* (cons roles acc))])))

;; 整篇 -> hash：括号位置 (line . col) -> 配对位置 (line . col)。
;; 只有严格匹配（栈顶 + 类型相同）的括号才会进入结果；不匹配的括号不产生键。
;; 位置只来自 lex.rkt 的 paren token，所以字符串 / 注释 / 字符字面量里的括号会被忽略。
(define (bracket-pair-map text)
  (define lines (split-lines text))
  (define token-lines (tokenize text))
  (define pairs (make-hash))
  (define stack '())        ; (listof (cons position open-char))
  (for ([line (in-list lines)]
        [tokens (in-list token-lines)]
        [ln (in-naturals)])
    (define n (string-length line))
    (for ([t (in-list tokens)] #:when (eq? (token-kind t) 'paren))
      (for ([col (in-range (token-start t) (min (token-end t) n))])
        (define ch (string-ref line col))
        (cond
          [(open-bracket? ch)
           (set! stack (cons (cons (cons ln col) ch) stack))]
          [(close-bracket? ch)
           (cond
             [(and (pair? stack) (matches? (cdar stack) ch))
              (define open-pos (caar stack))
              (define close-pos (cons ln col))
              (set! stack (cdr stack))
              (hash-set! pairs open-pos close-pos)
              (hash-set! pairs close-pos open-pos)]
             [else (void)])]))))
  pairs)

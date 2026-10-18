#lang racket

;;; plugins/highlight/lex.rkt —— 一个很小的 Racket 风格词法扫描（纯）
;;;
;;; layer  : plugins/highlight
;;; effect : 无（纯：文本 -> 每行的 face 区间）
;;;
;;; 只做四类：行注释 `;…`、块注释 `#|…|#`、字符串 `"…"`（含 \ 转义）、数字。
;;; 剩下的“词”再按关键字表上色（见 scan-tokens）。
;;;
;;; 返回值统一成 fills（和 core 的 face fill 同形状）：
;;;   (list l0 c0 l1 c1 face)        —— 半开区间 [c0, c1)
;;; 跨行状态（块注释深度 / 是否在字符串里）只在 lex-lines 内部使用。
;;;
;;; 行级接口 `syntax-line` 返回跨行状态 + 行 face 向量，供 face-decor 增量使用；
;;; `lex-fills` 是保留的整篇接口（旧 worker / 调试）。

(provide lex-fills
         syntax-line
         merge-fills
         keyword-set
         symbol-char?
         ident-start?
         line-tokens)

(require racket/list
         racket/string
         ;; “词字符”与补全 / 文档共用同一份定义（plugins/lang/word.rkt）。
         "../lang/word.rkt")

(define keyword-set
  (for/hash ([k (in-list '("define" "define-values" "lambda" "let" "let*" "let-values"
                           "letrec" "if" "cond" "case" "when" "unless" "begin" "set!"
                           "require" "provide" "module" "struct" "match" "for" "for/list"
                           "and" "or" "not" "quote" "quasiquote" "map" "filter" "foldl"
                           "cons" "car" "cdr" "list" "hash" "vector" "values" "apply"))])
    (values k #t)))

(define keyword-faces
  (hash "define" 'fg-syntax-def
        "define-values" 'fg-syntax-def
        "lambda" 'fg-syntax-control
        "if" 'fg-syntax-control
        "cond" 'fg-syntax-control
        "case" 'fg-syntax-control
        "when" 'fg-syntax-control
        "unless" 'fg-syntax-control
        "match" 'fg-syntax-control
        "for" 'fg-syntax-control
        "for/list" 'fg-syntax-control
        "set!" 'fg-syntax-control
        "begin" 'fg-syntax-control
        "let" 'fg-syntax-binding
        "let*" 'fg-syntax-binding
        "let-values" 'fg-syntax-binding
        "letrec" 'fg-syntax-binding
        "struct" 'fg-syntax-binding
        "require" 'fg-syntax-module
        "provide" 'fg-syntax-module
        "module" 'fg-syntax-module))

(define (keyword-face w)
  (hash-ref keyword-faces w 'fg-syntax-macro))

;; 一行：返回 (values 新状态 fills)，状态 = (cons block-depth in-string?)
(define (lex-line st line lno)
  (define n (string-length line))
  (define fills '())
  (define (paint! a b f)
    (when (< a b) (set! fills (cons (list lno a lno (min b n) f) fills))))
  (let loop ([i 0] [block (car st)] [in-str? (cdr st)])
    (cond
      [(>= i n) (values (cons block in-str?) (reverse fills))]

      ;; #| 开块注释
      [(and (not in-str?) (positive? block)) (paint! i (add1 i) 'fg-syntax-comment)
                                             (loop (add1 i) block #f)]
      [(and (not in-str?) (char=? #\# (string-ref line i)) (< (add1 i) n)
            (char=? #\| (string-ref line (add1 i))))
       (paint! i (+ i 2) 'fg-syntax-comment) (loop (+ i 2) (add1 block) #f)]
      [(and (positive? block) (char=? #\| (string-ref line i)) (< (add1 i) n)
            (char=? #\# (string-ref line (add1 i))))
       (paint! i (+ i 2) 'fg-syntax-comment) (loop (+ i 2) (sub1 block) #f)]

      ;; 字符串
      [(and (not (positive? block)) (char=? #\" (string-ref line i)))
       (paint! i (add1 i) 'fg-syntax-string) (loop (add1 i) block (not in-str?))]
      [in-str?
       (cond [(and (char=? #\\ (string-ref line i)) (< (add1 i) n))
              (paint! i (+ i 2) 'fg-syntax-string) (loop (+ i 2) block #t)]
             [else (paint! i (add1 i) 'fg-syntax-string) (loop (add1 i) block #t)])]

      ;; 行注释
      [(char=? #\; (string-ref line i)) (paint! i n 'fg-syntax-comment)
                                         (values (cons block #f) (reverse fills))]

      ;; 数字
      [(char-numeric? (string-ref line i))
       (define end (let next ([j (add1 i)])
                     (if (and (< j n)
                              (or (char-numeric? (string-ref line j))
                                  (char=? #\. (string-ref line j))
                                  (char=? #\/ (string-ref line j))))
                         (next (add1 j)) j)))
       (paint! i end 'fg-syntax-number) (loop end block #f)]

      [else (loop (add1 i) block #f)])))

;; 关键字：按词切分，跳过已被注释/字符串/数字占用的位置
(define (word-fills line lno occupied)
  (define n (string-length line))
  (define out '())
  (let loop ([i 0])
    (cond
      [(>= i n) (reverse out)]
      [(symbol-char? (string-ref line i))
       (define end (let next ([j i])
                     (if (and (< j n) (symbol-char? (string-ref line j))) (next (add1 j)) j)))
       (define w (substring line i end))
       (define busy? (for/or ([f (in-list occupied)])
                       (and (>= i (list-ref f 1)) (< i (list-ref f 3)))))
       (when (and (not busy?) (hash-has-key? keyword-set w))
         (set! out (cons (list lno i lno end (keyword-face w)) out)))
       (loop end)]
      [else (loop (add1 i))])))

;; 一行 -> (values 新状态 face 向量)。face 向量与字符一一对应，值 = face 符号 | #f。
;; 这是增量 decor 用的行级接口；lex-fills 仍保留给旧的整篇扫描 / worker。
(define (syntax-line st line lno)
  (define n (string-length line))
  (define-values (state* fills) (lex-line st line lno))
  (define words (word-fills line lno fills))
  (define vec (make-vector n #f))
  (for ([f (in-list fills)])
    (for ([i (in-range (list-ref f 1) (min n (list-ref f 3)))])
      (vector-set! vec i (list-ref f 4))))
  ;; 关键字只填空位，不覆盖注释 / 字符串 / 数字。
  (for ([f (in-list words)])
    (for ([i (in-range (list-ref f 1) (min n (list-ref f 3)))])
      (unless (vector-ref vec i)
        (vector-set! vec i (list-ref f 4)))))
  (values state* vec))

;; 整篇扫描：文本 -> fills
;; 合并同一行、同 face、首尾相接的区间（减少 fill 数）
(define (merge-fills fills)
  (define sorted
    (sort fills (λ (a b)
                  (or (< (list-ref a 0) (list-ref b 0))
                      (and (= (list-ref a 0) (list-ref b 0))
                           (< (list-ref a 1) (list-ref b 1)))))))
  (reverse
   (for/fold ([acc '()]) ([f (in-list sorted)])
     (cond
       [(null? acc) (list f)]
       [else
        (define p (car acc))
        (if (and (= (list-ref p 0) (list-ref f 0))       ; 同行
                 (= (list-ref p 2) (list-ref f 0))
                 (= (list-ref p 3) (list-ref f 1))       ; 首尾相接
                 (eq? (list-ref p 4) (list-ref f 4)))    ; 同 face
            (cons (list (list-ref p 0) (list-ref p 1) (list-ref f 2) (list-ref f 3)
                        (list-ref p 4))
                  (cdr acc))
            (cons f acc))]))))

(define (lex-fills text)
  (define lines (string-split text "\n"))
  (for/fold ([acc '()] [state (cons 0 #f)] #:result acc)
            ([line (in-list lines)] [lno (in-naturals)])
    (define-values (state* fills) (lex-line state line lno))
    (define words (word-fills line lno fills))
    (values (append acc (merge-fills (append fills words))) state*)))

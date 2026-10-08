#lang racket

;;; lab-re-rebuild/lang/source.rkt —— 从源码文本提取「需要哪些模块 / 定义了哪些名字」（纯）
;;;
;;; 只做启发式扫描，不做展开：把语言（`#lang` 或顶层 `(module …)`）与顶层
;;; `(require …)` 的模块路径找出来，供补全（module->exports）与文档查询（xref
;;; 反查定义）当候选集；再扫一遍顶层定义名。
;;;
;;; 读法：先跳过开头的空白 / `;` 行注释 / `#|…|#` 块注释 / `#;` 数据注释 /
;;; `#!` shebang（任意多个），再剥掉 `#lang` / `#reader` 行（reader 指令不是
;;; s-表达式），其余顶层表单逐个 `read`。
;;; 没有 `#lang` 时，顶层 `(module name lang body …)` 也算模块上下文（loader 允许
;;; 这种写法）。遇到读不了的（非 s-表达式语言 / 语法错误）就停在出错处，返回已有结果。
;;; 目的不是 100% 正确，而是「大多数普通 Racket 文件够用」。

(provide source-lang source-requires source-definitions require-context?
         module-context requires-context requires-of-forms definitions-of-forms)

(require racket/list racket/path racket/string)

;;; ================= reader =================

;; 从 i 起第一个 '\n' 的下标；没有则文本长度。用于一次跳过 ';' 注释 / shebang 行。
(define (line-end text i)
  (let loop ([j i])
    (cond [(>= j (string-length text)) (string-length text)]
          [(char=? (string-ref text j) #\newline) j]
          [else (loop (add1 j))])))

;; 跳过 '#;' 后的一个 datum，返回其后下标；读不出 / 到末尾返回 #f。
;; 借 Racket reader 读（它会跳过 datum 内的注释与嵌套 '#;'），用端口位置求长度。
(define (skip-sexp-comment text i)
  (define in (open-input-string (substring text (+ i 2))))
  (with-handlers ([exn:fail? (λ (_) #f)])
    (read in)
    (define used (file-position in))
    (and (number? used) (+ i 2 used))))

;; 跳过开头的空白 / `;` 行注释 / `#|…|#` 块注释（可嵌套）/ `#!` shebang 行 /
;; `#;` 数据注释，返回第一个「有意义」字符的下标。Racket 编译器就是这么做的：
;; `#lang` / `(module …)` 前面可以有任意多、任意种类的 trivia。
(define (skip-leading-trivia text)
  (define n (string-length text))
  (let loop ([i 0] [blk 0])
    (cond
      [(>= i n) n]
      [(positive? blk)
       (cond
         [(and (char=? (string-ref text i) #\#)
               (< (add1 i) n)
               (char=? (string-ref text (add1 i)) #\|))
          (loop (+ i 2) (add1 blk))]
         [(and (char=? (string-ref text i) #\|)
               (< (add1 i) n)
               (char=? (string-ref text (add1 i)) #\#))
          (loop (+ i 2) (sub1 blk))]
         [else (loop (add1 i) blk)])]
      [(char-whitespace? (string-ref text i)) (loop (add1 i) blk)]
      [(char=? (string-ref text i) #\;) (loop (line-end text i) blk)]
      [(and (char=? (string-ref text i) #\#)
            (< (add1 i) n)
            (char=? (string-ref text (add1 i)) #\|))
       (loop (+ i 2) 1)]
      [(and (char=? (string-ref text i) #\#)
            (< (add1 i) n)
            (char=? (string-ref text (add1 i)) #\!))
       (loop (line-end text i) blk)]
      [(and (char=? (string-ref text i) #\#)
            (< (add1 i) n)
            (char=? (string-ref text (add1 i)) #\;))
       (define next (skip-sexp-comment text i))
       (if next (loop next blk) i)]
      [else i])))

;; `#lang foo`（跳过开头空白 / 注释后）里 foo 是语言模块名（如 racket/base）。
(define (directive-lang text)
  (define m (regexp-match #px"^#lang\\s+(\\S+)" (substring text (skip-leading-trivia text))))
  (and m (string->symbol (cadr m))))

;; 剥掉开头的 reader 指令（`#lang` / `#reader` 行）：先跳过空白 / 注释 / shebang，
;; 若随后是 `#lang` / `#reader` 就整行拿掉；否则从第一个有效字符起返回。
(define (strip-reader-lines text)
  (define rest (substring text (skip-leading-trivia text)))
  (cond
    [(regexp-match? #rx"^#(lang|reader)" rest)
     (define nl (line-end rest 0))
     (if (< nl (string-length rest)) (substring rest (add1 nl)) "")]
    [else rest]))

;; 顶层表单列表；读到一半出错就停（返回已读到的）。
;; #:max-forms / #:max-chars 可选上界：`require` 按惯例都在文件头部，
;; 不必为了几行 require 把整篇 read 一遍（大文件 read 是超线性的）。
(define (read-forms text #:max-forms [max-forms #f] #:max-chars [max-chars #f])
  (define in (open-input-string (strip-reader-lines text)))
  (let loop ([acc '()] [n 0])
    (cond
      [(and max-forms (>= n max-forms)) (reverse acc)]
      [(and max-chars (>= (file-position in) max-chars)) (reverse acc)]
      [else
       (define d (with-handlers ([exn:fail? (λ (_) eof)]) (read in)))
       (cond
         [(eof-object? d) (reverse acc)]
         [else (loop (cons d acc) (add1 n))])])))

;;; ================= 模块上下文（语言 + 模块体） =================

;; 一个源码文件的模块上下文 → (values 语言spec 模块体表单)。
;;   · 有 #lang        → 语言 = #lang 的模块名；体 = #lang 之后的顶层表单。
;;   · 无 #lang，但首个表单是顶层 (module name lang body …)
;;                     → 语言 = lang；体 = body（loader 允许这种「无 #lang」写法）。
;;   · 都没有          → 语言 = #f；体 = 全部顶层表单（临时 / 半成品文本）。
(define (module-context text #:max-forms [max-forms #f] #:max-chars [max-chars #f])
  (define forms (read-forms text #:max-forms max-forms #:max-chars max-chars))
  (define lang (directive-lang text))
  (cond
    [lang (values lang forms)]
    [else
     (define f (and (pair? forms) (car forms)))
     (cond
       [(and (pair? f) (eq? (car f) 'module)
             (pair? (cdr f)) (pair? (cddr f)))
        (values (caddr f) (cdr (cddr f)))]
       [else (values #f forms)])]))

;; 文件自身的语言（#lang 模块名，或顶层 module 的语言 spec；无则 #f）。
(define (source-lang text)
  (define-values (lang _forms) (module-context text))
  lang)

;; require 专用：只需读文件头部。超过上界就停（宁可少认几个尾部 require，
;; 也不为它们把整篇 read 一遍）。
(define requires-max-forms 200)
(define requires-max-chars 131072)      ; 128KB
(define (requires-context text)
  (module-context text #:max-forms requires-max-forms #:max-chars requires-max-chars))

;;; ================= require 规格 → 模块路径 =================
;;; 结果可直接喂给 module->exports / xref：符号（'racket/list）或
;;; (lib "x.rkt") / (file "/abs/x.rkt") / (planet …)。

(define require-wrappers '(only-in except-in rename-in))

;; 把可能是「点对」（如读到一半的 `(require . x)`）的列表安全地当列表遍历，
;; 非法尾巴直接丢弃 —— source-requires 必须对任意编辑中的文本都是全函数。
(define (list-elems x)
  (let loop ([x x])
    (cond [(null? x) '()]
          [(pair? x) (cons (car x) (loop (cdr x)))]
          [else '()])))

;; 半成品 / 非法 spec 一律忽略（返回 '()）而不是抛错：编辑器里文本随时可能是
;; 写了一半的，扫描器必须对任意输入都是全函数。
(define (spec->paths s base-dir)
  (with-handlers ([exn:fail? (λ (_) '())])
    (cond
      [(symbol? s) (list s)]
      ;; 空串不是合法模块路径：build-path 会直接违约报错，先挡掉。
      [(string? s) (if (zero? (string-length s))
                       '()
                       (list (list 'file (path->complete-path (build-path base-dir s)))))]
      [(pair? s)
       (define h (car s))
       (cond
         [(memq h require-wrappers) (spec->paths (cadr s) base-dir)]
         [(memq h '(prefix-in prefix-rename-in)) (spec->paths (caddr s) base-dir)]
         [(memq h '(for-syntax for-template for-label)) (spec->paths (cadr s) base-dir)]
         [(eq? h 'for-meta) (append* (for/list ([x (in-list (cddr s))]) (spec->paths x base-dir)))]
         [(eq? h 'submod) (spec->paths (cadr s) base-dir)]
         [(eq? h 'combine-in) (append* (for/list ([x (in-list (cdr s))]) (spec->paths x base-dir)))]
         [(memq h '(lib file planet quote)) (list s)]
         [else '()])]
      [else '()])))

;; 候选模块路径：语言模块 + 所有 require（去重，语言模块排最前）。
(define (source-requires text #:base-dir [base-dir (current-directory)])
  (define-values (lang forms) (requires-context text))
  (requires-of-forms lang forms #:base-dir base-dir))

;; 已解析的「语言 + 模块体」版本：补全要同时要 requires 与 definitions 时，
;; 只需 `module-context` 解析一次，不要各自再 read 一遍全文。
(define (requires-of-forms lang forms #:base-dir [base-dir (current-directory)])
  (define reqs
    (append*
     (for/list ([f (in-list forms)]
                #:when (and (pair? f) (eq? (car f) 'require)))
       (append* (for/list ([s (in-list (list-elems (cdr f)))]) (spec->paths s base-dir))))))
  (remove-duplicates (append (spec->paths lang base-dir) reqs) equal?))

;;; ================= 顶层定义名 =================

;; (define name …) / (define (name args) …) / (define-syntax-rule (name args) …) → name
(define (define-names f)
  (define target (and (pair? (cdr f)) (cadr f)))
  (cond
    [(symbol? target) (list target)]
    [(and (pair? target) (symbol? (car target))) (list (car target))]
    [else '()]))

(define (def-names f)
  (cond
    [(not (pair? f)) '()]
    [else
     (case (car f)
       [(define define-syntax define-syntax-rule) (define-names f)]
       [(define-values)
        (if (and (pair? (cdr f)) (pair? (cadr f)))
            (filter symbol? (cadr f))
            '())]
       [(struct struct* define-struct)
        (let ([t (and (pair? (cdr f)) (cadr f))])
          (if (symbol? t) (list t) '()))]
       [else '()])]))

;; 符号去重（哈希 O(n)）；大文件里定义多时 remove-duplicates 的 O(n²) 会卡。
(define (distinct-symbols ss)
  (define seen (make-hasheq))
  (define rev
    (for/fold ([acc '()]) ([s (in-list ss)])
      (cond [(hash-ref seen s #f) acc]
            [else (hash-set! seen s #t) (cons s acc)])))
  (reverse rev))

(define (source-definitions text)
  (define-values (_lang forms) (module-context text))
  (definitions-of-forms forms))

;; 已解析的模块体版本（与 requires-of-forms 共享同一次 read）。
(define (definitions-of-forms forms)
  (distinct-symbols
   (append* (for/list ([f (in-list forms)]) (def-names f)))))

;;; ================= require 补全的上下文判定 =================

;; 光标前的文本（line/col 为 0-based）。
(define (text-before text line col)
  (define lines (string-split text "\n" #:trim? #f))
  (define n (length lines))
  (string-append
   (string-join (take lines (min line n)) "\n")
   (if (positive? line) "\n" "")
   (let ([l (if (< line n) (list-ref lines line) "")])
     (substring l 0 (min (max 0 col) (string-length l))))))

;; 最近一个未闭合 '(' 的下标；跳过字符串 / ';' 行注释 / '#|…|#' 块注释。
(define (last-open-paren s)
  (define n (string-length s))
  (let loop ([i 0] [stack '()] [str? #f] [esc? #f] [line? #f] [blk 0])
    (cond
      [(>= i n) (and (pair? stack) (car stack))]
      [else
       (define c (string-ref s i))
       (cond
         [line? (loop (add1 i) stack #f #f (not (char=? c #\newline)) blk)]
         [(> blk 0)
          (cond [(and (char=? c #\#) (< (add1 i) n) (char=? (string-ref s (add1 i)) #\|))
                 (loop (+ i 2) stack #f #f #f (add1 blk))]
                [(and (char=? c #\|) (< (add1 i) n) (char=? (string-ref s (add1 i)) #\#))
                 (loop (+ i 2) stack #f #f #f (sub1 blk))]
                [else (loop (add1 i) stack #f #f #f blk)])]
         [str? (cond [esc? (loop (add1 i) stack #t #f #f blk)]
                     [(char=? c #\\) (loop (add1 i) stack #t #t #f blk)]
                     [(char=? c #\") (loop (add1 i) stack #f #f #f blk)]
                     [else (loop (add1 i) stack #t #f #f blk)])]
         [(char=? c #\") (loop (add1 i) stack #t #f #f blk)]
         [(char=? c #\;) (loop (add1 i) stack #f #f #t blk)]
         [(and (char=? c #\#) (< (add1 i) n) (char=? (string-ref s (add1 i)) #\|))
          (loop (+ i 2) stack #f #f #f 1)]
         [(memv c '(#\( #\[ #\{)) (loop (add1 i) (cons i stack) #f #f #f blk)]
         [(memv c '(#\) #\] #\})) (loop (add1 i) (if (pair? stack) (cdr stack) '()) #f #f #f blk)]
         [else (loop (add1 i) stack #f #f #f blk)])])))

(define (tokens s)
  (for/list ([t (in-list (string-split s #px"[\\s()\\[\\]{}]+"))]
             #:unless (string=? t ""))
    t))

;; require 的模块路径位置（直接子表单 / 包装器的模块参数）。
(define module-heads '(require for-syntax for-template for-label for-meta combine-in))
(define first-arg-heads '(only-in except-in rename-in prefix-in prefix-rename-in submod))

;; 光标是否处于 require 的模块路径位置。
(define (require-context? text line col)
  (define before (text-before text line col))
  (define open (last-open-paren before))
  (and open
       (let* ([inside (substring before (add1 open))]
              [toks (tokens inside)])
         (and (pair? toks)
              (let ([head (string->symbol (car toks))]
                    [rest (cdr toks)])
                (cond
                  [(memq head module-heads) #t]
                  [(memq head first-arg-heads) (<= (length rest) 1)]
                  [else #f]))))))

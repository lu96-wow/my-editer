#lang racket

;;; lab-rebuild/lang/source.rkt —— 从源码文本提取「需要哪些模块 / 定义了哪些名字」（纯）
;;;
;;; 只做启发式扫描，不做展开：把 `#lang` 语言与顶层 `(require …)` 的模块路径找出来，
;;; 供补全（module->exports）与文档查询（xref 反查定义）当候选集；再扫一遍顶层定义名。
;;;
;;; 读法：剥掉 `#lang` / `#reader` 首行（reader 指令不是 s-表达式），其余顶层表单
;;; 逐个 `read`。遇到读不了的（非 s-表达式语言 / 语法错误）就停在出错处，返回已有结果。
;;; 目的不是 100% 正确，而是「大多数普通 Racket 文件够用」。

(provide source-lang source-requires source-definitions)

(require racket/list racket/path racket/string)

;;; ================= reader =================

;; `#lang foo` 里 foo 是语言模块名（如 racket/base）。
(define (source-lang text)
  (define m (regexp-match #px"^#lang\\s+(\\S+)" text))
  (and m (string->symbol (cadr m))))

(define (strip-reader-lines text)
  (define lines (string-split text "\n"))
  (cond
    [(and (pair? lines) (regexp-match? #rx"^#(lang|reader)" (car lines)))
     (string-join (cdr lines) "\n")]
    [else text]))

;; 顶层表单列表；读到一半出错就停（返回已读到的）。
(define (read-forms text)
  (define in (open-input-string (strip-reader-lines text)))
  (let loop ([acc '()])
    (define d (with-handlers ([exn:fail? (λ (_) eof)]) (read in)))
    (cond
      [(eof-object? d) (reverse acc)]
      [else (loop (cons d acc))])))

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
  (define lang (source-lang text))
  (define reqs
    (append*
     (for/list ([f (in-list (read-forms text))]
                #:when (and (pair? f) (eq? (car f) 'require)))
       (append* (for/list ([s (in-list (list-elems (cdr f)))]) (spec->paths s base-dir))))))
  (remove-duplicates (append (if lang (list lang) '()) reqs) equal?))

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

(define (source-definitions text)
  (remove-duplicates
   (append* (for/list ([f (in-list (read-forms text))]) (def-names f)))
   eq?))

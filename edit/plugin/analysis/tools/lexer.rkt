#lang racket

;;; edit/plugin/analysis/tools/lexer.rkt —— Racket 词法（纯，包 syntax-color）
;;;
;;; 文本 → (listof token)（0-based 字符偏移，半开 [start,end)）。
;;; 用 DrRacket 公共 lexer：module-lexer 处理 #lang / #reader 行并选语言 lexer，
;;; 失败则退回 racket-lexer。报位 1-based → 0-based；空 span 丢弃。
;;;
;;; ⚠ module-lexer 会 load #lang 语言模块（read-language），属「会执行代码」的边界；
;;;   只允许在 worker 里调（见 worker.rkt）。本模块不依赖 core / session / tui。

(require syntax-color/module-lexer
         syntax-color/racket-lexer
         "span.rkt")

(provide lex-text normalize-token)

;;; ---------- 类型归一 ----------

;; syntax-color 的 type 可能是 symbol，也可能是带 'type 键的 hash（* 变体）。
(define (type-symbol type)
  (if (hash? type) (hash-ref type 'type 'other) type))

(define (lang-directive? txt)
  (and (string? txt) (string-prefix? txt "#lang ")))

;; (type, 原文本) → 归一类型
(define (normalize-token type txt)
  (define t (type-symbol type))
  (cond
    [(and (eq? t 'parenthesis) (member txt '("(" "[" "{"))) 'open-paren]
    [(and (eq? t 'parenthesis) (member txt '(")" "]" "}"))) 'close-paren]
    [(equal? txt "'") 'quote]
    [(equal? txt "`") 'quasiquote]
    [(equal? txt ",") 'unquote]
    [(equal? txt "#;") 'sexp-comment]
    [(equal? txt "#'") 'syntax-quote]
    [(equal? txt "#`") 'syntax-quasiquote]
    [(equal? txt "#,@") 'syntax-unquote-splicing]
    [(equal? txt "#,") 'syntax-unquote]
    [(equal? txt ",@") 'unquote-splicing]
    [(equal? txt "#reader") 'reader-directive]
    [(and (eq? t 'other) (lang-directive? txt)) 'lang-directive]
    [else t]))

;;; ---------- 报位 ----------

;; 1-based [start,end) → 0-based；非正整数 → #f
(define (to0 pos) (and (exact-positive-integer? pos) (sub1 pos)))

(define (record-span type txt start end)
  (define s (to0 start))
  (define e (to0 end))
  (and s e (< s e) (token (span s e) (normalize-token type txt))))

;;; ---------- 状态化 lexer ----------
;;; syntax-color lexer 可能是：arity-1 过程（每次读一个 token）、arity-3 过程
;;; （in offset mode → 带 backup/new-mode）、或 (proc . mode) 对。统一成 step。

(define (state-proc lx) (if (pair? lx) (car lx) lx))
(define (state-mode lx) (if (pair? lx) (cdr lx) #f))
(define (make-state proc mode) (if mode (cons proc mode) proc))

;; → (values txt type start end 下一状态) 或 (values eof ...)
(define (step-lexer lx in)
  (define proc (state-proc lx))
  (cond
    [(procedure-arity-includes? proc 1)
     (define-values (txt type _paren start end) (proc in))
     (values txt type start end lx)]
    [else
     (define mode (state-mode lx))
     (define-values (txt type _paren start end _backup next-mode) (proc in 0 mode))
     (values txt type start end (make-state proc next-mode))]))

;;; ---------- 主入口 ----------

(define (lex-text text [path #f])
  (define dir (and path (let-values ([(d _f _r) (split-path path)]) d)))
  (parameterize ([current-load-relative-directory dir])
    (define in (open-input-string text))
    (port-count-lines! in)
    (define initial
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (call-with-values (lambda () (module-lexer in 0 #f)) list)))
    (cond
      ;; 语言模块加载失败：重开端口，退回 racket-lexer 全扫
      [(not initial)
       (define in2 (open-input-string text))
       (port-count-lines! in2)
       (scan-loop in2 '() racket-lexer)]
      [else
       (match-define (list t0 ty0 _p0 s0 e0 _bk0 nm0) initial)
       (define tk0 (record-span ty0 t0 s0 e0))
       (scan-loop in (if tk0 (list tk0) '())
                  (if (or (procedure? nm0) (pair? nm0)) nm0 racket-lexer))])))

(define (scan-loop in out lx)
  (define-values (txt type start end lx*)
    (with-handlers ([exn:fail? (lambda (_) (values eof #f #f #f lx))])
      (step-lexer lx in)))
  (cond
    [(eof-object? txt) (reverse out)]
    [else
     (define tk (record-span type txt start end))
     (scan-loop in (if tk (cons tk out) out) lx*)]))

#lang racket

(require racket/set
         racket/path
         "../../core/text/base/line.rkt"
         "api.rkt"
         "lex.rkt")

;;; lab/plugin/syntax.rkt —— Racket 关键字固定色（内置插件）
;;;
;;; 只对 Racket 源文件生效（按扩展名：.rkt / .rktl / .rktd / .scrbl）。
;;; 标识符 token 命中关键字表 → 固定 face 'syn-keyword（前景色由主题给）。
;;; 注册在词着色插件**之后** → 关键字与词色同层叠起，主题合并时关键字（后层）前景覆盖词色。
;;;
;;; 无状态：open/change 都整篇重扫。

(provide syntax-plugin)

;; path-get-extension 返回 bytes（如 #".rkt" / #f）
(define racket-exts '(#".rkt" #".rktl" #".rktd" #".scrbl"))

(define (racket-file? path)
  (and path (member (path-get-extension path) racket-exts)))

(define keywords
  (for/set ([k (in-list
                '("define" "define-values" "define-syntax" "define-struct"
                  "lambda" "λ"
                  "let" "let*" "letrec" "let-values" "let*-values" "letrec-values"
                  "if" "cond" "case" "when" "unless" "begin" "and" "or" "not"
                  "require" "provide" "module" "module*" "struct" "struct*"
                  "match" "match*" "match-lambda"
                  "for" "for/list" "for/fold" "for/and" "for/or" "for/vector"
                  "set!" "quote" "quasiquote" "unquote" "unquote-splicing"
                  "with-handlers" "parameterize" "else" "syntax-rules"))])
    k))

(define (syntax-fills text)
  (for/list ([tok (in-list (scan-words text))]
             #:when (set-member? keywords (cadddr tok)))
    (match-define (list ln s e _w) tok)
    (list ln s ln e 'syn-keyword)))

(define (syntax-open text path)
  (values #f (if (racket-file? path) (syntax-fills text) '())))

(define (syntax-change _state _edits lines path)
  (syntax-open (lines->string (vector->list lines)) path))

(define syntax-plugin
  (plugin 'syntax syntax-open syntax-change))

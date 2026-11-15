#lang racket

;;; edit-tui/lang/c/completion/completion.rkt —— C 补全候选（纯 / 同步）
;;;
;;; 候选池：
;;;   · 常见 C / POSIX / Unix / Linux lib 函数、宏、类型；
;;;   · C 关键字 / 类型 / 常用常量；
;;;   · 当前 buffer 的代码标识符（跳过注释 / 字符串 / 预处理行）。
;;;
;;; 不做跨文件语义分析；头文件导出 / 宏展开留给以后。

(require racket/list
         racket/string
         "../base/lex.rkt"
         "../base/keywords.rkt"
         "../data/lib.rkt")

(provide c-completion-prefix
         c-completion-at
         c-completion-pool
         c-completion-local-pool
         c-completion-filter
         c-completion-rank
         c-completion-insert-text
         c-include-context?
         c-header-completion-at)

(define (line-at text line)
  (define lines (c-text-lines text))
  (if (and (exact-nonnegative-integer? line) (< line (length lines)))
      (list-ref lines line)
      ""))

(define (ident-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

(define (line-prefix text line col)
  (define s (line-at text line))
  (define c (min (max 0 col) (string-length s)))
  (substring s 0 c))

;; 光标是否在 #include <...> / #include "..." 里。
(define (c-include-context? text line col)
  (regexp-match? #rx"^[ \t]*#[ \t]*include[ \t]*[<\"][^>\"]*$"
                 (line-prefix text line col)))

(define (header-char? c)
  (or (char-alphabetic? c)
      (char-numeric? c)
      (memv c '(#\_ #\/ #\. #\- #\+))))

(define (header-prefix text line col)
  (define s (line-at text line))
  (define c (min (max 0 col) (string-length s)))
  (define start
    (let loop ([i c])
      (if (and (> i 0) (header-char? (string-ref s (sub1 i))))
          (loop (sub1 i))
          i)))
  (substring s start c))

;; 光标前的 C 标识符前缀；在 #include 行里改成头文件前缀。
(define (c-completion-prefix text line col)
  (if (c-include-context? text line col)
      (header-prefix text line col)
      (let* ([s (line-at text line)]
             [c (min (max 0 col) (string-length s))]
             [start
              (let loop ([i c])
                (if (and (> i 0) (ident-char? (string-ref s (sub1 i))))
                    (loop (sub1 i))
                    i))])
        (substring s start c))))

(define (distinct-strings ss)
  (define seen (make-hash))
  (reverse
   (for/fold ([acc '()]) ([s (in-list ss)])
     (cond
       [(hash-ref seen s #f) acc]
       [else (hash-set! seen s #t) (cons s acc)]))))

(define (symbol->name x)
  (cond [(symbol? x) (symbol->string x)]
        [(string? x) x]
        [else (format "~a" x)]))

(define (c-completion-local-pool text)
  (distinct-strings (c-symbols-in-text text)))

(define (c-completion-pool text)
  (distinct-strings
   (append c-lib-names
           (map symbol->name c-keyword-names)
           (map symbol->name c-type-names)
           (map symbol->name c-constant-names)
           (c-completion-local-pool text))))

(define (c-completion-filter pool prefix)
  (define plen (string-length prefix))
  (for/list ([x (in-list pool)]
             #:when (and (>= (string-length x) plen)
                         (string=? prefix (substring x 0 plen))))
    x))

(define (c-completion-rank cands)
  (sort cands
        (lambda (a b)
          (cond [(< (string-length a) (string-length b)) #t]
                [(> (string-length a) (string-length b)) #f]
                [else (string<? a b)]))))

;; path / text / line / col -> (listof string)
;; #:local-only? 目前只影响是否先截断：C 静态池很小，完整池也可以直接给首屏。
(define (c-completion-at _path text line col
                         #:local-only? [local-only? #f])
  (define include? (c-include-context? text line col))
  (define prefix (c-completion-prefix text line col))
  (cond
    [(and (zero? (string-length prefix)) (not include?)) '()]
    [else
     (if include?
         ;; 头文件保持“常用优先”的顺序，不按长度重排。
         (c-completion-filter c-header-names prefix)
         (c-completion-rank
          (c-completion-filter (c-completion-pool text) prefix)))]))

;; 只给 include 行用的入口（测试 / 宿主显式调用）。
(define (c-header-completion-at text line col)
  (define prefix (header-prefix text line col))
  (c-completion-filter c-header-names prefix))

(define (c-completion-insert-text candidate prefix)
  (substring candidate (min (string-length prefix) (string-length candidate))))

#lang racket

;;; lab-rebuild/smoke-lang.rkt —— 语言层（文档查询 / 补全）回归
;;;
;;; 逐步测试由 raco test lab 跑。这里只做结构断言，减少对具体文档内容的耦合。

(require rackunit
         "lang/ident.rkt"
         "lang/source.rkt"
         "lang/docs.rkt"
         "lang/complete.rkt")

;;; ---------- ident ----------

(check-false (identifier-at "" 0 0))
(check-equal? (identifier-at "(define (foo x) (+ x 1))" 0 10) "foo")
(check-equal? (identifier-at "(define (foo x) (+ x 1))" 0 11) "foo")     ; 紧跟词尾
(check-equal? (identifier-at "(define foo 1)" 0 9) "foo")               ; 词首
(check-false (identifier-at "(define  foo 1)" 0 8))                     ; 空格处
(check-equal? (identifier-at "a/b.c?d" 0 6) "a/b.c?d")
(check-equal? (prefix-at "racket/li" 0 9) "racket/li")
(check-equal? (prefix-at "abc def" 0 7) "def")
(check-equal? (prefix-at "abc" 0 0) "")
(check-equal? (line-at "a\nbb\nccc" 1) "bb")
(check-equal? (line-at "a" 9) "")

;;; ---------- source ----------

(check-equal? (source-lang "#lang racket/base\n(define x 1)") 'racket/base)
(check-false (source-lang "(define x 1)"))
(check-equal? (source-requires
               "#lang racket/base\n(require racket/list (only-in racket/string string-split))")
              '(racket/base racket/list racket/string))
(check-equal? (source-requires
               "#lang racket\n(require (for-syntax racket/base) (prefix-in p: racket/list))")
              '(racket racket/base racket/list))
(check-equal? (source-definitions
               "#lang racket/base\n(define x 1)\n(define (f y) y)\n(struct P (a))\n(define-values (a b) (values 1 2))")
              '(x f P a b))
;; reader 指令头剥掉后还能读后面的表单
(check-equal? (source-requires "#reader scribble/reader\n(require racket/list)")
              '(racket/list))

;;; ---------- complete ----------

(check-not-false (member "add-between" (completions "add-" #:modules '(racket/list))))
(check-not-false (member "define" (completions "def")))                 ; 基础命名空间
(check-not-false (member "my-fn" (completions "my" #:locals '(my-fn other))))
;; 前缀过滤：不应出现不匹配的
(check-false (for/first ([s (in-list (completions "add-" #:modules '(racket/list)))]
                         #:unless (string-prefix? s "add-"))
               #t))
;; limit
(check-true (<= (length (completions "" #:modules '(racket/base) #:limit 10)) 10))

;;; ---------- docs ----------

(define d (docs-for "add-between" #:modules '(racket/list)))
(check-not-false d)
(check-equal? (doc-name d) "add-between")
(check-not-false (doc-signature d))
(check-not-false (and (string-contains? (doc-signature d) "add-between") #t))
(check-not-false (and (doc-description d) (string-contains? (doc-description d) "between each pair") #t))
(check-not-false (and (doc-url d) (string-prefix? (doc-url d) "https://docs.racket-lang.org/") #t))
(check-false (docs-for "definitely-not-a-racket-identifier-xyz" #:modules '(racket/base)))
;; doc->text 至少含名字与签名
(check-not-false (and (doc->text d) (string-contains? (doc->text d) "add-between") #t))

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
;; 编辑中的半成品 / 非法 require 不能让扫描器抛错（曾经 (require "") 触发 build-path 违约）
(check-equal? (source-requires "#lang racket\n(require \"\")") '(racket))
(check-equal? (source-requires "#lang racket\n(require . x)") '(racket))
(check-equal? (source-requires "#lang racket\n(require racket/list . x)") '(racket racket/list))

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
;; DrRacket 式：整个 bluebox 列表都显示，首行是类别
(check-not-false (and (string-prefix? (doc-signature d) "procedure") #t))
(check-false (docs-for "definitely-not-a-racket-identifier-xyz" #:modules '(racket/base)))
;; doc->text 至少含名字与签名；无 HTML 正文（不抽 prose / 不去 markdown）
(check-not-false (and (doc->text d) (string-contains? (doc->text d) "add-between") #t))
(check-false (string-contains? (doc->text d) "https://"))

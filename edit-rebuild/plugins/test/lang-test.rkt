#lang racket

;;; edit-rebuild/plugins/test/lang-test.rkt —— 语言服务（source 解析 / 候选池）（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/lang-test.rkt
;;;
;;; 覆盖：#lang+require 解析、顶层定义名、require 上下文判定、模块导出与候选池过滤。

(require rackunit
         racket/file
         "../lang/source.rkt"
         "../lang/pool.rkt")

;;; ---------- source ----------

(define src "#lang racket/base\n(require racket/list)\n(define (f x) x)\n(define-values (a b) 1)\n")
(define-values (lang forms) (requires-context src))
(check-equal? lang 'racket/base)
(check-not-false (member 'racket/list (requires-of-forms lang forms)))
(check-equal? (definitions-of-forms forms) '(f a b))

;; 顶层 (module name lang body)（无 #lang）
(define src2 "(module m racket/base (require racket/string) (define x 1))")
(define-values (lang2 forms2) (module-context src2))
(check-equal? lang2 'racket/base)
(check-not-false (member 'racket/string (requires-of-forms lang2 forms2)))

;; require 上下文判定
(check-true (require-context? "(require racket/lis" 0 18))
(check-true (require-context? "(require (only-in racket/lis" 0 28))
(check-false (require-context? "(+ 1 2" 0 5))
(check-false (require-context? "racket/list" 0 11))

;; #lang 的语言名位置（同样补模块路径）
(check-true (lang-context? "#lang rac" 0 8))
(check-true (lang-context? "#lang " 0 6))
(check-false (lang-context? "(require rac" 0 11))
(check-false (lang-context? "abc" 0 3))

;;; ---------- 候选池 ----------

(check-not-false (member "first" (module-exports 'racket/list)))
(check-not-false (member "first"
                         (completion-pool #:modules '(racket/list)
                                          #:locals '(my-fn)
                                          #:words '("foo"))))

;; 绝对路径模块路径不会让 module-exports 崩（取不到就空）
(check-equal? (module-exports '(file "../../../../../../../no/such/module.rkt")) '())

;;; ---------- require spec → 绑定名（only / except / prefix / rename） ----------

(define dir (current-directory))
(check-not-false (member "first" (spec-names 'racket/list dir)))
(check-equal? (spec-names '(only-in racket/list first) dir) '("first"))
(check-equal? (spec-names '(prefix-in l: (only-in racket/list first second)) dir)
              '("l:first" "l:second"))
(check-false (member "first" (spec-names '(except-in racket/list first) dir)))
(check-not-false (member "head" (spec-names '(rename-in racket/list (first head)) dir)))
(check-false (member "first" (spec-names '(rename-in racket/list (first head)) dir)))

;; 本地文件 require（path 形式：module-declared? 后才能取导出）
(define lp (make-temporary-file "spec-~a.rkt"))
(display-to-file "#lang racket/base\n(provide local-thing)\n(define local-thing 1)\n" lp #:exists 'replace)
(check-equal? (spec-names (path->string lp) dir) '("local-thing"))
(delete-file lp)

;;; ---------- provides-of-forms（打开的本地文件用缓冲区文本） ----------

(check-equal?
 (provides-of-forms
  "#lang racket/base\n(provide foo (all-defined-out) (struct-out posn))\n(define foo 1)\n(define bar 2)\n(struct posn (x y))\n")
 '("foo" "bar" "posn" "posn?" "posn-x" "posn-y"))

;; spec-names 带 open：命中的本地文件改用缓冲区文本（不登磁盘）
(define open (make-hash))
(hash-set! open "/tmp/spec-lib.rkt" "#lang racket/base\n(provide live-name)\n(define live-name 1)\n")
(check-equal? (spec-names "/tmp/spec-lib.rkt" (current-directory) open) '("live-name"))
(check-equal? (spec-names '(prefix-in p: "/tmp/spec-lib.rkt") (current-directory) open)
              '("p:live-name"))

;; spec-binding-of：候选名（prefix-in/rename-in 后）反查 (模块, 原名)
(check-equal? (spec-binding-of "first" '((only-in racket/list first)) dir)
              (list 'racket/list "first"))
(check-equal? (spec-binding-of "l:first" '((prefix-in l: racket/list)) dir)
              (list 'racket/list "first"))
(check-equal? (spec-binding-of "head" '((rename-in racket/list (first head))) dir)
              (list 'racket/list "first"))
(check-false (spec-binding-of "first" '((except-in racket/list first)) dir))
(check-equal? (spec-binding-of "other" '((except-in racket/list first)) dir)
              (list 'racket/list "other"))
(check-equal? (spec-binding-of "p:first" '((prefix-in p: (only-in racket/list first))) dir)
              (list 'racket/list "first"))

;; filter-pool：前缀过滤、长度升序（同长字典序）、保留与前缀相同的项
(check-equal? (filter-pool '("beta" "alpha" "alphabet") "alph")
              '("alpha" "alphabet"))
(check-equal? (filter-pool '("alpha" "alphabet") "alpha")
              '("alpha" "alphabet"))        ; 保留 "alpha" 自身
(check-equal? (filter-pool '("alpha") "alpha")
              '("alpha"))                    ; 只剩自身也保留
(check-equal? (filter-pool '("bb" "a" "ccc" "ab" "aaa") "a")
              '("a" "ab" "aaa"))           ; 保留 "a" 自身

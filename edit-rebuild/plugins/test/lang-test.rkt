#lang racket

;;; edit-rebuild/plugins/test/lang-test.rkt —— 语言服务（source 解析 / 候选池）（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/lang-test.rkt
;;;
;;; 覆盖：#lang+require 解析、顶层定义名、require 上下文判定、模块导出与候选池过滤。

(require rackunit
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

;;; ---------- 候选池 ----------

(check-not-false (member "first" (module-exports 'racket/list)))
(check-not-false (member "first"
                         (completion-pool #:modules '(racket/list)
                                          #:locals '(my-fn)
                                          #:words '("foo"))))

;; 绝对路径模块路径不会让 module-exports 崩（取不到就空）
(check-equal? (module-exports '(file "../../../../../../../no/such/module.rkt")) '())

;; filter-pool：前缀过滤、长度升序（同长字典序）、排除与前缀相同的项
(check-equal? (filter-pool '("beta" "alpha" "alphabet") "alph")
              '("alpha" "alphabet"))
(check-equal? (filter-pool '("alpha" "alphabet") "alpha")
              '("alphabet"))                 ; 排除 "alpha" 自身
(check-equal? (filter-pool '("alpha") "alpha")
              '())                           ; 只剩自身 → 空
(check-equal? (filter-pool '("bb" "a" "ccc" "ab" "aaa") "a")
              '("ab" "aaa"))                ; 排除 "a" 自身

#lang racket

;;; edit4-test/lang.rkt —— 语言服务启发式：require 解析 + 名字来源反查

(require rackunit
         "../edit4/plugins/lang/source.rkt"
         "../edit4/plugins/lang/pool.rkt")

(define base (current-directory))

;;; ---------- require 解析 ----------

(define text "#lang racket\n(require racket/list)\n(define (f x) (map add1 x))\n")
(define-values (lang forms) (requires-context text))
(check-equal? lang 'racket)
(check-equal? (requires-of-forms lang forms #:base-dir base) '(racket racket/list))
(check-equal? (definitions-of-forms forms) '(f))

;;; ---------- 名字来源反查：裸 require 必须验证导出，不能无条件认领 ----------

;; map 来自 racket（racket/list 不导出）——之前会错认成第一个 require racket/list
(check-equal? (spec-binding-of "map" '(racket/list racket) base) (list 'racket "map"))
(check-equal? (spec-binding-of "add1" '(racket/list racket) base) (list 'racket "add1"))
;; first 来自 racket/list
(check-equal? (spec-binding-of "first" '(racket/list racket) base) (list 'racket/list "first"))
;; 都不导出 / 本地定义 → #f（不再乱挂钩）
(check-false (spec-binding-of "no-such-name-xyz" '(racket/list racket) base))
(check-false (spec-binding-of "f" '(racket/list racket) base))

;;; ---------- 包装 spec 精确解析 ----------

(check-equal? (spec-binding-of "x" '((only-in racket/base x) racket) base) (list 'racket/base "x"))
(check-equal? (spec-binding-of "y" '((rename-in racket/base [x y]) racket) base) (list 'racket/base "x"))
(check-equal? (spec-binding-of "l:map" '((prefix-in l: racket) racket/base) base) (list 'racket "map"))

(displayln "edit4/lang.rkt: all tests passed")

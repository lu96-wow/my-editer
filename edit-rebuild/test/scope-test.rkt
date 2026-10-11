#lang racket

;;; edit-rebuild/test/scope-test.rkt —— 作用域判定（纯）

(require rackunit
         "../core/scope.rkt")

(define ctx
  (context 'editor 'docs 'editor
           (hash 'docs #t 'log #f)
           (hash 'interaction 'docs 'menu 'open)
           #f))
(define pctx (context 'editor #f 'editor (hash) (hash) 'C-p))

;; 基础
(check-true (scope-satisfied? (scope-always) ctx))
(check-true (scope-satisfied? (scope-focus 'editor) ctx))
(check-false (scope-satisfied? (scope-focus 'docs) ctx))
(check-true (scope-satisfied? (scope-focus-id 'docs) ctx))
(check-false (scope-satisfied? (scope-focus-id 'tree) ctx))
(check-true (scope-satisfied? (scope-focus-kind 'editor) ctx))
(check-false (scope-satisfied? (scope-focus-kind 'dock) ctx))

;; 显隐
(check-true (scope-satisfied? (scope-visible 'docs) ctx))
(check-false (scope-satisfied? (scope-visible 'log) ctx))   ; 显式为 #f
(check-false (scope-satisfied? (scope-visible 'nope) ctx))  ; 缺省 = 不可见

;; 模式
(check-true (scope-satisfied? (scope-mode= 'interaction 'docs) ctx))
(check-false (scope-satisfied? (scope-mode= 'interaction 'complete) ctx))
(check-false (scope-satisfied? (scope-mode= 'nope 'x) ctx))

;; 前缀
(check-false (scope-satisfied? (scope-prefix) ctx))
(check-true (scope-satisfied? (scope-prefix) pctx))

;; 组合
(check-true (scope-satisfied? (scope-and (scope-visible 'docs) (scope-mode= 'interaction 'docs)) ctx))
(check-false (scope-satisfied? (scope-and (scope-visible 'docs) (scope-mode= 'interaction 'complete)) ctx))
(check-true (scope-satisfied? (scope-or (scope-visible 'nope) (scope-visible 'docs)) ctx))
(check-true (scope-satisfied? (scope-not (scope-visible 'log)) ctx))
(check-false (scope-satisfied? (scope-not (scope-visible 'docs)) ctx))
(check-true (scope-satisfied? (scope-and) ctx))     ; 空 and = 真
(check-false (scope-satisfied? (scope-or) ctx))     ; 空 or = 假

#lang racket

;;; edit3-test/lang.rkt —— require 词表（source 解析 + pool 的 rename-in 绑定名 + 补全接入）

(require rackunit racket/list racket/file
         "../../edit3/core/extension.rkt"
         "../../edit3/core/step.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/core/session.rkt"
         "../../edit3/plugins/completion.rkt"
         "../../edit3/plugins/lang/source.rkt"
         "../../edit3/plugins/lang/pool.rkt")

(define tmp (make-temporary-file "ed3lang~a" 'directory))
(define SZ (cons 80 24))
(define (run1 st ev) (call-with-values (lambda () (step (refresh-panels! st) SZ ev)) (lambda (s e) s)))

;;; ---------- source：provide 名 ----------

(check-true (and (member "foo" (provides-of-forms "(provide foo)\n")) #t))
(check-true (and (member "a" (provides-of-forms "(define a 1)\n(provide a)\n")) #t))
(check-true (and (member "pt?" (provides-of-forms "(struct pt (x))\n(provide (struct-out pt))\n")) #t))
(check-true (and (member "b" (provides-of-forms "(provide (rename-out [a b]))\n")) #t))

;;; ---------- pool：spec → 最终绑定名 ----------

(define d (make-temporary-file "ed3langbase~a" 'directory))

;; only-in：只保留列出的
(check-equal? (sort (spec-names '(only-in racket/list first) d) string<?) '("first"))

;; rename-in：显式改名 + 其余导出保留
(define rn (spec-names '(rename-in racket/list [first zfirst]) d))
(check-true (and (member "zfirst" rn) #t))
(check-false (member "first" rn))                 ; 原名被换掉
(check-true (and (member "rest" rn) #t))          ; 未改名的仍在

;; prefix-in：统一加前缀
(define pf (spec-names '(prefix-in l: racket/list) d))
(check-true (and (member "l:first" pf) #t))
(check-false (member "first" pf))

;; prefix-rename-in：前缀 + 显式改名
(define pr (spec-names '(prefix-rename-in p: racket/list [first f]) d))
(check-true (and (member "p:f" pr) #t))
(check-true (and (member "p:rest" pr) #t))
(check-false (member "p:first" pr))

;; 本地文件（已打开 → 用当前缓冲区文本）
(define loc (build-path d "loc.rkt"))
(define loc-abs (path->string (path->complete-path loc)))
(define open (hash loc-abs "(provide alpha beta)\n"))
(check-equal? (sort (spec-names "loc.rkt" d open) string<?) '("alpha" "beta"))
(check-equal? (spec-local-paths "loc.rkt" d) (list loc-abs))
;; 未打开且磁盘不存在 → 空（不炸）
(check-equal? (spec-names "missing.rkt" d #f) '())

;; 反查来源（候选名 → 模块 / 原名）
(check-equal? (spec-binding-of "zfirst" '((rename-in racket/list [first zfirst])) d)
              (list 'racket/list "first"))
(check-equal? (spec-binding-of "l:first" '((prefix-in l: racket/list)) d)
              (list 'racket/list "first"))

;;; ---------- 补全接入：require 改名后的词进候选 ----------

(define f2 (build-path tmp "a.rkt"))
(display-to-file "(require (rename-in racket/list [first zfirst]))\nz\n"
                 f2 #:exists 'truncate)

(define b0 (boot 80 24 #:plugins (list completion-spec)))
(define-values (b1 _) (open-file* b0 f2))
(set-point! (state-ed b1) (focused-vid b1) 1 1)   ; 光标在第 1 行 "z" 之后
(define b2 (run1 b1 (key-event '/ '(alt))))
(check-true (and (feature-ref b2 'completion #f) #t))
(define cands (hash-ref (feature-ref b2 'completion #f) 'candidates))
(check-true (and (member "zfirst" cands) #t))     ; 只可能来自 rename-in

(delete-directory/files d)
(delete-directory/files tmp)

(displayln "edit3/lang.rkt: all tests passed")

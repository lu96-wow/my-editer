#lang racket

;;; edit2-test/mode.rkt —— 文件 → document 键表的匹配层（纯）

(require rackunit
         "../../edit2/core/mode.rkt")

(define p (string->path "/tmp/x/foo.rkt"))
(define mf (string->path "/tmp/x/Makefile"))

;; matcher 形态
(check-true  (matcher-match? '(ext "rkt") p))
(check-false (matcher-match? '(ext "txt") p))
(check-false (matcher-match? '(ext "rkt") mf))
(check-true  (matcher-match? '(name "foo.rkt") p))
(check-false (matcher-match? '(name "bar.rkt") p))
(check-true  (matcher-match? '(name "Makefile") mf))
(check-true  (matcher-match? '(regexp "foo") p))
(check-false (matcher-match? '(regexp "bar") p))
(check-true  (matcher-match? '(any) mf))
(check-false (matcher-match? '(ext "rkt") (string->path "/tmp/x/noext")))

;; 顺序 = 优先级：第一个命中
(check-equal? (match-doc-keys p (list (cons '(ext "txt") 'a) (cons '(ext "rkt") 'b))) 'b)
(check-equal? (match-doc-keys p (list (cons '(ext "rkt") 'a) (cons '(any) 'b))) 'a)
(check-equal? (match-doc-keys p (list (cons '(ext "txt") 'a))) #f)

(displayln "edit2/mode.rkt: all tests passed")

#lang racket

;;; edit2-test/prompt.rkt —— 输入行语义注册表（纯）

(require rackunit
         "../../edit2/core/prompt.rkt")

(define reg
  (make-prompt-kind-registry
   (list (cons 'a (lambda (st p text) (values st (list 'ran text)))))))

(check-equal? (call-with-values (lambda () ((prompt-kind-lookup reg 'a) 'S 'P "x")) list)
              (list 'S (list 'ran "x")))
(check-false (prompt-kind-lookup reg 'nope))

;; 覆盖 = 新表；旧表不变
(define reg2 (prompt-kind-register reg 'a (lambda (st p text) (values st (list 'two)))))
(check-equal? (call-with-values (lambda () ((prompt-kind-lookup reg2 'a) 'S 'P "x")) list)
              (list 'S (list 'two)))
(check-equal? (call-with-values (lambda () ((prompt-kind-lookup reg 'a) 'S 'P "x")) list)
              (list 'S (list 'ran "x")))

(displayln "edit2/prompt.rkt: all tests passed")

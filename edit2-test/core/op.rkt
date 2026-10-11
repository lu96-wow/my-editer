#lang racket

;;; edit2-test/op.rkt —— 原语注册表（纯）

(require rackunit
         "../../edit2/core/op.rkt")

(define r0
  (make-op-registry
   (list (cons 'x (lambda (ctx st ev args) (values st (list 'ran args)))))))

;; 命中：handler 拿到 args
(check-equal? (call-with-values (lambda () (op-run r0 #f 'S 'E '(x 1 2))) list)
              (list 'S (list 'ran '(1 2))))

;; 未知 tag → 原样返回（不报错，和旧 case 的 else 一致）
(check-equal? (call-with-values (lambda () (op-run r0 #f 'S 'E '(nope))) list)
              (list 'S '()))

;; 覆盖 = 返回新表；旧表不变
(define r1 (op-register r0 'x (lambda (ctx st ev args) (values st (list 'v2)))))
(check-equal? (call-with-values (lambda () (op-run r1 #f 'S 'E '(x))) list) (list 'S (list 'v2)))
(check-equal? (call-with-values (lambda () (op-run r0 #f 'S 'E '(x 9))) list)
              (list 'S (list 'ran '(9))))

(displayln "edit2/op.rkt: all tests passed")

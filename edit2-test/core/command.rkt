#lang racket

;;; edit2-test/core/command.rkt —— 声明式命令数据模型的外部测试

(require rackunit
         "../../edit2/core/command.rkt"
         "../../edit2/core/route.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/event.rkt")

;; binding 数据 → 守卫
(check-true ((parse-binding '(key a ctrl)) #f (key-event 'a '(ctrl))))
(check-false ((parse-binding '(key a ctrl)) #f (key-event 'a '())))
(check-true ((parse-binding '(cursor press left)) #f (cursor-event 'press 'left 1 2)))
(check-true ((parse-binding '(cursor scroll)) #f (cursor-event 'scroll 'up 1 2)))
(check-true ((parse-binding '(text)) #f (text-event "x")))

;; entry → route：runner 把「原语序列」当结果，便于断言
(define table
  '(((key a)         always (one))
    ((key b)         editor (one) (two))
    ((key c)         (panel tree) (three))))
(define (scope-of s) always)
(define routes
  (compile-routes table scope-of
                  (lambda (binding ops) (handled (lambda (st ev) (values st (list (length ops))))))))
(define c (ctx (cons 10 10) '()))

(check-equal? (call-with-values (lambda () (route-input routes c (make-state) (key-event 'a '()))) list)
              (list (make-state) '(1)))
(check-equal? (call-with-values (lambda () (route-input routes c (make-state) (key-event 'b '()))) list)
              (list (make-state) '(2)))

;; 作用域不命中 → 不派发
(define routes2
  (compile-routes '(((key a) editor (one))) (lambda (s) (lambda (st ev) #f))
                  (lambda (binding ops) (handled (lambda (st ev) (values st (list (length ops))))))))
(check-equal? (call-with-values (lambda () (route-input routes2 c (make-state) (key-event 'a '()))) list)
              (list (make-state) '()))

(displayln "edit2/core/command.rkt: all tests passed")

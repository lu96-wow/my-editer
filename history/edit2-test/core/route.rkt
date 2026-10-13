#lang racket

;;; edit2-test/route.rkt —— edit2/route.rkt 的外部测试

(require rackunit
         "../../edit2/core/route.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/event.rkt")

(define c (ctx (cons 10 10) '()))

;; 无人接 → 原状态、空效果
(check-equal? (call-with-values (lambda () (route-input '() c (make-state) (key-event 'a '()))) list)
              (list (make-state) '()))

;; 第一条命中并终止
(define r1 (route (lambda (st ev) #t) (handled (lambda (st ev) (values st '(hit))))))
(define r2 (route (lambda (st ev) #t) (handled (lambda (st ev) (values st '(miss))))))
(check-equal? (call-with-values (lambda () (route-input (list r1 r2) c (make-state) (key-event 'a '()))) list)
              (list (make-state) '(hit)))

;; 命中后交接 → 跑下一条
(define r-pass (route (lambda (st ev) #t) pass))
(check-equal? (call-with-values (lambda () (route-input (list r-pass r2) c (make-state) (key-event 'a '()))) list)
              (list (make-state) '(miss)))

;; 守卫不命中 → 跳过
(define r-no (route (lambda (st ev) #f) (handled (lambda (st ev) (values st '(no))))))
(check-equal? (call-with-values (lambda () (route-input (list r-no r2) c (make-state) (key-event 'a '()))) list)
              (list (make-state) '(miss)))

;; 守卫组合子
(check-true ((guard-and (lambda (st ev) #t) (lambda (st ev) #t)) (make-state) #f))
(check-false ((guard-and (lambda (st ev) #t) (lambda (st ev) #f)) (make-state) #f))
(check-true ((guard-not (lambda (st ev) #f)) (make-state) #f))

(displayln "edit2/route.rkt: all tests passed")

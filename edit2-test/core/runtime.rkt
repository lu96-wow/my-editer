#lang racket

;;; edit2-test/runtime.rkt —— edit2/runtime.rkt 的外部测试（假后端驱动真 core）

(require rackunit
         "../../edit2/core/runtime.rkt"
         "../../edit2/core/step.rkt"
         "../../edit2/core/event.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/adapter.rkt")

;; 脚本：编辑（变脏）→ C-q 弹「保存?」→ n → Enter → 退出。
;; 必须保证最终一定退出，否则主循环会一直等事件。
(define script
  (list (text-event "Z")
        (key-event 'q '(ctrl))
        (text-event "n")
        (key-event 'enter '())))
(define pending (box script))
(define draws 0)
(define b
  (backend
   (lambda () (cons 60 6))
   (lambda ()
     (if (pair? (unbox pending))
         (begin0 (car (unbox pending)) (set-box! pending (cdr (unbox pending))))
         (key-event 'q '(ctrl))))          ; 兜底：再来就退
   (lambda (pieces) (set! draws (add1 draws)))
   void))
(define st-final (run b (app-routes) (boot "abc" "t" 60 6)))
(check-true (>= draws 2))
(check-equal? (document-string (state-ed st-final) (focused-did st-final)) "Zabc")

(displayln "edit2/runtime.rkt: all tests passed")

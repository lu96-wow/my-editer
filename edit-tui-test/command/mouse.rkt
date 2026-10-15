#lang racket

;;; 由 edit-tui/command/mouse.rkt 的测试外移而来（edit-tui 只留实现）。
;;; 原测试用私有构造子 mouse-token；外移后改用公开访问器取字段比对。
(require rackunit
         "../../edit-tui/command/mouse.rkt")

(define (mt action button mods)
  (let ([m (apply mouse action button mods)])
    (list (mouse-action m) (mouse-button m) (mouse-mods m))))

(check-equal? (mt 'press 'left '()) '(press left ()))
(check-equal? (mt 'press 'left '(ctrl shift)) '(press left (ctrl shift)))
(check-equal? (mt 'scroll 'up '()) '(scroll up ()))
(check-equal? (mt 'move #f '()) '(move #f ()))
;; 严格：无修饰 ≠ 有修饰
(check-not-equal? (mouse 'press 'left) (mouse 'press 'left 'ctrl))
;; 校验
(check-exn exn:fail? (λ () (mouse 'click 'left)))
(check-exn exn:fail? (λ () (mouse 'press 'mid)))
(check-exn exn:fail? (λ () (mouse 'move 'left)))
(check-equal? (mouse->string (mouse 'press 'left 'ctrl)) "C-left press")

(displayln "edit-tui/command/mouse.rkt: ok")

#lang racket

;;; 由 edit-tui/command/keymap.rkt 的测试外移而来（edit-tui 只留实现）。
(require rackunit
         "../../edit-tui/command/keymap.rkt"
         "../../edit-tui/command/key.rkt")

(define base
  (keys [(key 'left)                       (λ () 'left)]
        [(key 'x 'ctrl) (key 's 'ctrl)     (λ () 'save)]
        [(key 'p 'ctrl) (key 'up)          (λ () 'focus-up)]))

;; 精确查：单键 / 多键 / 前缀未到底
(check-equal? ((keymap-ref base (list (key 'left)))) 'left)
(check-equal? ((keymap-ref base (list (key 'x 'ctrl) (key 's 'ctrl)))) 'save)
(check-equal? ((keymap-ref base (list (key 'p 'ctrl) (key 'up)))) 'focus-up)
(check-false (keymap-ref base (list (key 'x 'ctrl))))
(check-false (keymap-ref base (list (key 'nope))))

;; 单步推进
(define-values (s1 e1) (keymap-step base (key 'x 'ctrl)))
(check-equal? s1 'prefix)
(check-true (keymap? e1))
(define-values (s2 e2) (keymap-step base (key 'left)))
(check-equal? s2 'command)
(check-equal? (e2) 'left)
(define-values (s3 _) (keymap-step base (key 'zz)))
(check-equal? s3 'unbound)

;; 合并：后表覆盖同序列
(define user (keys [(key 'x 'ctrl) (key 's 'ctrl) (λ () 'save-as)]))
(define m (keymap-merge (list base user)))
(check-equal? ((keymap-ref m (list (key 'x 'ctrl) (key 's 'ctrl)))) 'save-as)
;; 不冲突的续键都保留（前缀递归合并）
(define m2 (keymap-merge (list base (keys [(key 'x 'ctrl) (key 'c 'ctrl) (λ () 'quit)]))))
(check-equal? ((keymap-ref m2 (list (key 'x 'ctrl) (key 's 'ctrl)))) 'save)
(check-equal? ((keymap-ref m2 (list (key 'x 'ctrl) (key 'c 'ctrl)))) 'quit)
;; 前缀整体也是「同一个键」：后表用叶子覆盖前缀
(define m3 (keymap-merge (list base (keys [(key 'x 'ctrl) (λ () 'x-only)]))))
(check-equal? ((keymap-ref m3 (list (key 'x 'ctrl)))) 'x-only)
(check-false (keymap-ref m3 (list (key 'x 'ctrl) (key 's 'ctrl))))

(displayln "edit-tui/command/keymap.rkt: ok")

#lang racket

;;; 由 edit-tui/command/keymap.rkt 的测试外移而来（edit-tui 只留实现）。
;;; 新版：keytable = 表列表操作对象；merge 冲突报错；lookup 走前缀序列。
(require rackunit
         "../../edit-tui/command/keymap.rkt"
         "../../edit-tui/command/key.rkt")

(define (status kt seq)
  (call-with-values (λ () (keytable-lookup kt seq)) (λ (s _) s)))
(define (value kt seq)
  (call-with-values (λ () (keytable-lookup kt seq))
    (λ (_ e) (and (procedure? e) (e)))))

(define base
  (keys [(key 'left)                       (λ () 'left)]
        [(key 'x 'ctrl) (key 's 'ctrl)     (λ () 'save)]
        [(key 'p 'ctrl) (key 'up)          (λ () 'focus-up)]))

(define kt (make-keytable base))

;; 查表：单键 / 多键 / 前缀未到底 / 未绑定
(check-equal? (status kt (list (key 'left))) 'command)
(check-equal? (value  kt (list (key 'left))) 'left)
(check-equal? (value  kt (list (key 'x 'ctrl) (key 's 'ctrl))) 'save)
(check-equal? (value  kt (list (key 'p 'ctrl) (key 'up))) 'focus-up)
(check-equal? (status kt (list (key 'x 'ctrl))) 'prefix)
(check-equal? (status kt (list (key 'nope))) 'unbound)

;; 冲突：同一序列两个叶子
(check-exn exn:fail?
  (λ () (keytable-merge! kt (keys [(key 'left) (λ () 'other)]))))
;; 冲突：叶子 vs 前缀（C-x 与 C-x C-s）
(check-exn exn:fail?
  (λ () (keytable-merge! kt (keys [(key 'x 'ctrl) (λ () 'x-only)]))))
;; 冲突：前缀 vs 叶子（先有 C-x 叶子，再并入 C-x C-s）
(check-exn exn:fail?
  (λ () (keytable-merge! kt (keys [(key 'y 'ctrl) (λ () 'y-only)])
                         (keys [(key 'y 'ctrl) (key 's 'ctrl) (λ () 'y-s)]))))
;; 失败是原子的：上面的失败没污染 kt
(check-equal? (status kt (list (key 'x 'ctrl))) 'prefix)
(check-equal? (status kt (list (key 'y 'ctrl))) 'unbound)
(check-equal? (status kt (list (key 'y 'ctrl) (key 's 'ctrl))) 'unbound)

;; 不冲突：同前缀、不同续键都能留下
(void (keytable-merge! kt (keys [(key 'x 'ctrl) (key 'c 'ctrl) (λ () 'quit)])))
(check-equal? (value kt (list (key 'x 'ctrl) (key 's 'ctrl))) 'save)
(check-equal? (value kt (list (key 'x 'ctrl) (key 'c 'ctrl))) 'quit)
(check-equal? (status kt (list (key 'x 'ctrl))) 'prefix)

;; 批次一起并：新表之间也要查冲突（且整体原子）
(define kt2 (make-keytable))
(check-exn exn:fail?
  (λ () (keytable-merge! kt2
                         (keys [(key 'q) (λ () 1)])
                         (keys [(key 'q) (λ () 2)]))))
(check-equal? (status kt2 (list (key 'q))) 'unbound)

;; 运行时动态修改：空表 → 并表后立即可查
(define kt3 (make-keytable))
(check-equal? (status kt3 (list (key 'a))) 'unbound)
(void (keytable-merge! kt3 (keys [(key 'a) (λ () 'a)])))
(check-equal? (value kt3 (list (key 'a))) 'a)
;; 整份替换也可（结构体是 mutable 的）
(set-keytable-tables! kt3 '())
(check-equal? (status kt3 (list (key 'a))) 'unbound)

;; keys 产出的仍是一张普通表；make-keytable 可直接带初值
(check-equal? (value (make-keytable base) (list (key 'left))) 'left)

(displayln "edit-tui/command/keymap.rkt: ok")

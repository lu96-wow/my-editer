#lang racket

;;; edit2-test/keymap.rkt —— 键表组合（纯）

(require rackunit
         "../../edit2/core/keymap.rkt")

;; 组合：后表在 (binding scope) 相同时覆盖前表
(define t1 '(((key a) always (one))))
(define t2 '(((key a) always (two)) ((key b) always (three))))
(check-equal? (compose-keymaps (list t1 t2))
              '(((key a) always (two)) ((key b) always (three))))

;; 不同 scope 不算重合 → 两条都保留
(define t3 '(((key a) editor (four))))
(check-equal? (compose-keymaps (list t2 t3))
              '(((key a) always (two)) ((key b) always (three)) ((key a) editor (four))))

;; 空表 / 顺序
(check-equal? (compose-keymaps '()) '())
(check-equal? (compose-keymaps (list t1)) t1)

;; 单条加/覆盖
(check-equal? (keymap-add t1 '((key a) always (five))) '(((key a) always (five))))
(check-equal? (keymap-add t1 '((key c) always (six)))
              '(((key a) always (one)) ((key c) always (six))))

(displayln "edit2/keymap.rkt: all tests passed")

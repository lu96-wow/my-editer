#lang racket

;;; 命令表 / 表 stack / 键序列 / 动态遮蔽测试。
(require rackunit
         "../main.rkt")

(define (lookup table seq)
  (let-values ([(st v) (command-table-lookup table seq)])
    (cons st v)))

(define (stack-lookup stack seq)
  (let-values ([(st v) (command-table-stack-lookup stack seq)])
    (cons st v)))

;;; ---------- 单表 / 键序列 ----------
(define base
  (keys
   ['a        'cmd-a]
   ['b 'c     'cmd-bc]
   ['x 's     'cmd-xs]))

(check-equal? (lookup base '(a)) (cons 'command 'cmd-a))
(check-equal? (lookup base '(b c)) (cons 'command 'cmd-bc))
(check-equal? (lookup base '(b)) (cons 'prefix #f))
(check-equal? (lookup base '(x)) (cons 'prefix #f))
(check-equal? (lookup base '(x s)) (cons 'command 'cmd-xs))
(check-equal? (lookup base '(nope)) (cons 'unbound #f))

(check-true (command-table-exact? base '(a)))
(check-false (command-table-exact? base '(b)))
(check-true (command-table-prefix? base '(b)))
(check-false (command-table-prefix? base '(nope)))

;;; ---------- 合并：左边优先 ----------
(define t1 (keys ['a 'from-t1] ['only1 'v1]))
(define t2 (keys ['a 'from-t2] ['only2 'v2]))

(define merged (command-table-merge t1 t2))
(check-equal? (lookup merged '(a)) (cons 'command 'from-t1)) ; t1 在左
(check-equal? (lookup merged '(only1)) (cons 'command 'v1))
(check-equal? (lookup merged '(only2)) (cons 'command 'v2))

(define merged-rev (command-table-merge t2 t1))
(check-equal? (lookup merged-rev '(a)) (cons 'command 'from-t2))

;;; ---------- stack：动态遮蔽 ----------
(define popup
  (keys
   ['b        'popup-b]
   ['c        'popup-c]
   ['x 'p     'popup-xp]))

(define stack0 (command-table-stack-from-tables (list base)))
(define stack1 (command-table-stack-push stack0 popup))

;; a 在 popup 里没有 → 落到 base
(check-equal? (stack-lookup stack1 '(a)) (cons 'command 'cmd-a))
;; b 被 popup 遮蔽
(check-equal? (stack-lookup stack1 '(b)) (cons 'command 'popup-b))
;; c 只在 popup
(check-equal? (stack-lookup stack1 '(c)) (cons 'command 'popup-c))
;; x 在 popup 是 prefix → 停住，不落到 base
(check-equal? (stack-lookup stack1 '(x)) (cons 'prefix #f))
;; x p 命中 popup
(check-equal? (stack-lookup stack1 '(x p)) (cons 'command 'popup-xp))

;; pop 后回到 base
(define stack2 (command-table-stack-pop stack1))
(check-equal? (stack-lookup stack2 '(b)) (cons 'prefix #f))
(check-equal? (stack-lookup stack2 '(b c)) (cons 'command 'cmd-bc))

;; remove 指定表
(define stack3 (command-table-stack-remove stack1 popup))
(check-equal? (stack-lookup stack3 '(b)) (cons 'prefix #f))
(check-equal? (stack-lookup stack3 '(b c)) (cons 'command 'cmd-bc))

;; 空 stack
(check-equal? (stack-lookup command-table-stack-empty '(a)) (cons 'unbound #f))
(check-equal? (command-table-stack-tables command-table-stack-empty) '())

;;; ---------- 合并 + stack ----------
(define merged-stack
  (command-table-stack-from-tables (list (command-table-merge t1 t2))))
(check-equal? (stack-lookup merged-stack '(a)) (cons 'command 'from-t1))
(check-equal? (stack-lookup merged-stack '(only2)) (cons 'command 'v2))

(displayln "edit-tui-rebuild/test/command-table.rkt: ok")

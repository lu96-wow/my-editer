#lang racket

;;; edit-tui/test/interaction.rkt —— LIFO interaction 栈（纯）
;;;
;;; 覆盖：
;;;   1. push / top / pop；
;;;   2. 按 id / kind 移除；
;;;   3. find；
;;;   4. State 上的 interaction 助手；
;;;   5. 构造校验。

(require rackunit
         "../model/interaction.rkt"
         "../model/state.rkt")

(define i1 (make-interaction 'placement 'placement #f))
(define i2 (make-interaction 'confirm 'confirm 'confirm-data))
(define i3 (make-interaction 'input 'input 'input-data))

(check-eq? (interaction-top (interaction-empty)) #f)
(define st1 (interaction-push (interaction-empty) i1))
(check-eq? (interaction-top st1) i1)
(define st2 (interaction-push st1 i2))
(check-eq? (interaction-top st2) i2)
(define st3 (interaction-push st2 i3))
(check-eq? (interaction-top st3) i3)

;; pop 只弹栈顶
(check-eq? (interaction-top (interaction-pop st3)) i2)
;; 按 id 移除（不在栈顶也能删）
(define st4 (interaction-pop-id st3 'confirm))
(check-equal? (map interaction-id st4) '(input placement))
;; 按 kind 移除
(define st5 (interaction-pop-kind st3 'input))
(check-equal? (map interaction-id st5) '(confirm placement))
;; find
(check-eq? (interaction-find st3 'confirm) i2)
(check-false (interaction-find st3 'nope))
;; 原栈不变
(check-equal? (map interaction-id st3) '(input confirm placement))

;;; ════════════════ State 助手 ════════════════

(define s0 (make-state))
(check-eq? (state-interaction-top s0) #f)
(define s1 (state-interaction-push s0 i1))
(check-eq? (state-interaction-top s1) i1)
(check-eq? (state-interaction-top s0) #f)
(define s2 (state-interaction-push s1 i2))
(check-equal? (map interaction-id (state-interactions s2)) '(confirm placement))
(define s3 (state-interaction-pop-id s2 'placement))
(check-equal? (map interaction-id (state-interactions s3)) '(confirm))
(define s4 (state-interaction-pop-kind s2 'confirm))
(check-equal? (map interaction-id (state-interactions s4)) '(placement))
(define s5 (state-interaction-pop-kind s4 'placement))
(check-equal? (state-interactions s5) '())

;;; ════════════════ 构造校验 ════════════════

(check-exn exn:fail? (λ () (make-interaction "not-symbol" 'x #f)))
(check-exn exn:fail? (λ () (make-interaction 'id "not-symbol" #f)))
(check-eq? (interaction-data (make-interaction 'id 'x 'anything)) 'anything)

(displayln "edit-tui interaction: ok")

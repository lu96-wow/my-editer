#lang racket

;;; edit/core/test/overlay-test.rkt —— 浮层焦点栈（纯）
;;;
;;;   raco test edit/core/test/overlay-test.rkt
;;;
;;; 覆盖：open 不抢焦点 / focus! 移到栈头 / close 回落 / cycle 轮换 / deep 派生。

(require rackunit
         "../app/app.rkt"
         "../session/overlay.rkt")

(define s (app-session 80 24 #:plugins '()))

(check-false (session-overlay-focus s))

;; open：第一个自动成为栈头；已有焦点时追加到栈尾（不抢）
(define s1 (session-overlay-open s 'docs))
(check-eq? (session-overlay-focus s1) 'docs)
(define s2 (session-overlay-open s1 'complete))
(check-eq? (session-overlay-focus s2) 'docs)          ; complete 没有抢焦点
(define s2b (session-overlay-open s2 'docs))           ; 重复 open 幂等
(check-eq? (session-overlay-focus s2b) 'docs)

;; focus!：移到栈头，z 序随之切换
(define s3 (session-overlay-focus! s2b 'complete))
(check-eq? (session-overlay-focus s3) 'complete)
(check-equal? (overlay-deep s3 'complete 2000) 3000)
(check-equal? (overlay-deep s3 'docs 100) 100)

;; cycle：栈头移到栈尾
(define s4 (session-overlay-cycle s3))
(check-eq? (session-overlay-focus s4) 'docs)
(check-equal? (overlay-deep s4 'docs 100) 3000)
(define s4b (session-overlay-cycle s4))
(check-eq? (session-overlay-focus s4b) 'complete)

;; close：回落
(define s5 (session-overlay-close s4b 'complete))
(check-eq? (session-overlay-focus s5) 'docs)
(define s6 (session-overlay-close s5 'docs))
(check-false (session-overlay-focus s6))

;; 空栈 / 单元素 cycle 不崩
(define s7 (session-overlay-cycle s6))
(check-false (session-overlay-focus s7))
(define s8 (session-overlay-cycle s7))
(check-false (session-overlay-focus s8))

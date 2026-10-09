#lang racket

;;; edit/test/hook-test.rkt —— 生命周期通知机制验证（headless）
;;;
;;;   raco test edit/test/hook-test.rkt
;;;
;;; 覆盖：after-edit（改文本的原语后触发，带 vid）/ focus-changed（设焦点后触发）。

(require rackunit
         "../demo.rkt"
         "../session.rkt"
         "../feature/api.rkt")

(define s (demo-session 80 24))
(define ae (box #f))
(define fc (box #f))
(define s1
  (session-add-hook
   (session-add-hook s
                     (hook 'after-edit (lambda (s a) (set-box! ae (car a)) s)))
   (hook 'focus-changed (lambda (s a) (set-box! fc (car a)) s))))

(define-values (s2 did vid) (session-add-document s1 "abc" 40 18 #:name "*t*"))
(define s3 (session-show-view s2 vid))          ; show-view 设焦点 → focus-changed
(check-equal? (unbox fc) vid)

(define s4 (session-insert s3 "X"))             ; 改文本 → after-edit
(check-equal? (unbox ae) vid)

;; 只读原语不触发 after-edit
(set-box! ae #f)
(define s5 (session-nav s4 'right #f))
(check-false (unbox ae))

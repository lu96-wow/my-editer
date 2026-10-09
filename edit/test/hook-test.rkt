#lang racket

;;; edit/test/hook-test.rkt —— 生命周期通知机制验证（headless）
;;;
;;;   raco test edit/test/hook-test.rkt
;;;
;;; 覆盖：after-edit / after-insert（改文本的原语后触发，带 vid changes）/ focus-changed
;;;       / document-closed；服务注册表 session-service-ref/put。

(require rackunit
         "../demo.rkt"
         "../session.rkt"
         "../feature/api.rkt")

(define s (demo-session 80 24))
(define ae (box #f))
(define ai (box #f))
(define fc (box #f))
(define dc (box #f))
(define s1
  (session-add-hook
   (session-add-hook
    (session-add-hook
     (session-add-hook s
                       (hook 'after-edit (lambda (s a) (set-box! ae a) s)))
     (hook 'after-insert (lambda (s a) (set-box! ai a) s)))
    (hook 'focus-changed (lambda (s a) (set-box! fc (car a)) s)))
   (hook 'document-closed (lambda (s a) (set-box! dc (car a)) s))))

;; 服务注册表：命名状态可存可取
(define s0 (session-service-put s1 'demo 'value))
(check-eq? (session-service-ref s0 'demo) 'value)
(check-false (session-service-ref s0 'missing))

(define-values (s2 did vid) (session-add-document s1 "abc" 40 18 #:name "*t*"))
(define s3 (session-show-view s2 vid))          ; show-view 设焦点 → focus-changed
(check-equal? (unbox fc) vid)

(define s4 (session-insert s3 "X"))             ; 改文本 → after-edit + after-insert (vid changes)
(check-equal? (car (unbox ae)) vid)
(check-true (pair? (cadr (unbox ae))))           ; changes 非空
(check-equal? (car (unbox ai)) vid)
(check-true (pair? (cadr (unbox ai))))

;; 只读原语不触发 after-edit
(set-box! ae #f)
(define s5 (session-nav s4 'right #f))
(check-false (unbox ae))

;; 关文档 → document-closed (did)
(define s6 (session-close-document s5 did))
(check-equal? (unbox dc) did)

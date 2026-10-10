#lang racket

;;; edit-rebuild/core/test/session-edit-test.rkt —— 焦点 / 通知 / 操作原语（headless）
;;;
;;;   raco test edit-rebuild/core/test/session-edit-test.rkt

(require rackunit
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../session/hook.rkt"
         "../session/focus.rkt"
         "../session/edit.rkt"
         "../surface/surface.rkt"
         "../focus.rkt")

(define s (session-blank 80 24))
(define-values (s1 did vid)
  (session-add-document s "abc" 40 10 #:name "*t*"))

(define fc (box #f)) (define ae (box #f)) (define ai (box #f)) (define an (box #f))
(define s2
  (session-add-hook
   (session-add-hook
    (session-add-hook
     (session-add-hook s1
       (hook 'focus-changed (lambda (s a) (set-box! fc (car a)) s)))
     (hook 'after-edit (lambda (s a) (set-box! ae a) s)))
    (hook 'after-insert (lambda (s a) (set-box! ai a) s)))
   (hook 'after-nav (lambda (s a) (set-box! an (car a)) s))))

;; 焦点设到编辑视图 → 更新 edit-vid + focus-changed
(define s3 (session-set-focus s2 (focus-set (session-focus s2) vid)))
(check-equal? (unbox fc) vid)
(check-equal? (session-edit-vid s3) vid)

;; 插入 → after-edit + after-insert（带 vid changes）
(define s4 (session-insert s3 "X"))
(check-equal? (session-view-string s4 vid) "Xabc")
(check-equal? (car (unbox ae)) vid)
(check-true (pair? (cadr (unbox ae))))
(check-equal? (car (unbox ai)) vid)

;; 导航 → after-nav (vid)
(set-box! an #f)
(define s5 (session-nav s4 'right #f))
(check-equal? (unbox an) vid)

;; 删除 → after-edit 触发（只读不触发）
(set-box! ae #f)
(define s5b (session-backspace s5))
(check-true (pair? (unbox ae)))

;; 焦点落到 dock 面 → 粘性 edit-vid 不变
(define sf (float-surface 'pop 999 #f (float (lambda (_) #f) 10) #f #f #f #f))
(define s6 (session-set-focus (session-add-surface s5b sf)
                              (focus-set (session-focus s5b) 999)))
(check-equal? (session-edit-vid s6) vid)

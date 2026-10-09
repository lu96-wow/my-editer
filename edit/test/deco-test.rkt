#lang racket

;;; edit/test/deco-test.rkt —— 叠加层（deco）能力验证（headless）
;;;
;;;   raco test edit/test/deco-test.rkt
;;;
;;; 覆盖：deco 每帧产 placed（进 session-panes / 命中 / deep）/ overlay 标记（dock、不入缓冲区）
;;;       / 去掉 deco 几何消失。

(require rackunit
         "../demo.rkt"
         "../session.rkt"
         "../feature/api.rkt")

(define s (demo-session 80 24))
(define-values (s1 did vid) (session-add-document s "pop\nup" 8 2 #:name "*pop*"))
(define x 5)
(define y 3)

;; 叠加：登记 vid + 每帧产 placed 的 deco
(define s2 (session-overlay-add s1 vid))
(define s3 (session-deco-add s2 (deco 'test (lambda (_s) (list (placed vid x y 8 2 1000))))))

(define p (for/first ([p (in-list (session-panes s3))] #:when (eqv? (placed-vid p) vid)) p))
(check-true (and p #t))
(check-equal? (placed-x p) x)
(check-equal? (placed-y p) y)
(check-equal? (placed-deep p) 1000)
(check-equal? (session-view-at s3 x y) vid)          ; 命中最高层
(check-true (session-dock-vid? s3 vid))               ; 视作叠加/dock
(check-true (and (memv did (session-overlay-dids s3)) #t))

;; 去掉 deco → 不进几何
(define s4 (session-deco-remove s3 'test))
(check-false (for/first ([p (in-list (session-panes s4))] #:when (eqv? (placed-vid p) vid)) #t))

;; 去掉 overlay 标记 + 关文档
(define s5 (session-close-document (session-overlay-remove s4 vid) did))
(check-false (session-dock-vid? s5 vid))

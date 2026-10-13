#lang racket

;;; edit-rebuild/core/test/border-test.rkt —— 窗口边框（内核布局能力 + 交点）
;;;
;;;   raco test edit-rebuild/core/test/border-test.rkt
;;;
;;; 有边框的面：外框画边框，内容四周内缩 1；两个边框共享一条边时，交点取 T 字形
;;; （├ / ┤），而不是两个角（└/┌）叠在一起。

(require rackunit
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../session/render.rkt"
         "../surface/surface.rkt"
         "../geometry/layout.rkt")

(define (cell rends r c)
  (for/first ([p (in-list rends)] #:when (and (= (piece-row p) r) (= (piece-column p) c))) p))
(define (txt rends r c) (define p (cell rends r c)) (and p (piece-text p)))

;; 单个有边框的浮动窗：外框 (2,1) 8x5，内容内缩到 (3,2) 6x3
(define s0 (session-blank 40 12))
(define-values (s1 _d1 v1) (session-add-document s0 "abc" 10 3 #:name "*a*"))
(define s2 (session-add-surface s1
             (float-surface 'a v1 #f (float (lambda (_) (area 2 1 8 5)) 5)
                            #f #f #f #f #:border 'window-border)))
(check-equal? (session-pane-inset s2 v1) 1)
(define-values (s3 _n1 r1 _e1) (session-render s2 #f))
(check-equal? (txt r1 1 2) "┌──────┐")
(check-equal? (txt r1 5 2) "└──────┘")
(check-equal? (txt r1 2 2) "│")
(check-equal? (txt r1 2 9) "│")
(check-equal? (txt r1 2 3) "abc")

;; 第二个边框窗紧贴其下（共享第 5 行）→ 交点应为 ├ / ┤
(define-values (s4 _d2 v2) (session-add-document s3 "xyz" 10 3 #:name "*b*"))
(define s5 (session-add-surface s4
             (float-surface 'b v2 #f (float (lambda (_) (area 2 5 8 5)) 6)
                            #f #f #f #f #:border 'window-border)))
(define-values (s6 _n2 r2 _e2) (session-render s5 #f))
(check-equal? (txt r2 5 2) "├──────┤")   ; 共享边：左端 ├、右端 ┤、中间 ─
(check-equal? (txt r2 9 2) "└──────┘")     ; 下窗自己的底边
(check-equal? (txt r2 6 2) "│")
(check-equal? (txt r2 6 3) "xyz")

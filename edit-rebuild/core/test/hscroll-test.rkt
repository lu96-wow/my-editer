#lang racket

;;; edit-rebuild/core/test/hscroll-test.rkt —— 水平移动视口（clip 模式 left-column）
;;;
;;;   raco test edit-rebuild/core/test/hscroll-test.rkt

(require rackunit
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../session/render.rkt"
         "../surface/surface.rkt"
         "../geometry/layout.rkt")

(define s0 (session-blank 20 5))
(define-values (s1 _did vid)
  (session-add-document s0 "abcdefghijklmnopqrstuvwxyz" 10 3 #:name "*t*"))
(define s2 (session-add-surface s1
             (float-surface 'x vid #f (float (lambda (_) (area 0 0 10 3)) 5)
                            #f #f #f #f)))

(define (row0 rends) (for/first ([p (in-list rends)] #:when (= 0 (piece-row p))) p))

(define-values (s3 _n1 r1 _e1) (session-render s2 #f))
(check-equal? (piece-text (row0 r1)) "abcdefghij")     ; 视口从第 0 列开始

(define s4 (session-ed-hscroll! s3 vid 5))
(define-values (s5 _n2 r2 _e2) (session-render s4 #f))
(check-equal? (piece-text (row0 r2)) "fghijklmno")     ; 右移 5 列

(define s6 (session-ed-hscroll! s5 vid -3))
(define-values (s7 _n3 r3 _e3) (session-render s6 #f))
(check-equal? (piece-text (row0 r3)) "cdefghijkl")     ; 左移 3 列

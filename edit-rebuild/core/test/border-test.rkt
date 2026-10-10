#lang racket

;;; edit-rebuild/core/test/border-test.rkt —— 窗口边框（内核布局能力）
;;;
;;;   raco test edit-rebuild/core/test/border-test.rkt
;;;
;;; 有边框的面：外框画边框，内容四周内缩 1；无边框的面内容铺满。

(require rackunit
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../session/render.rkt"
         "../surface/surface.rkt"
         "../geometry/layout.rkt")

(define (cell rends r c)
  (for/first ([p (in-list rends)] #:when (and (= (piece-row p) r) (= (piece-column p) c))) p))

;; 有边框的浮动窗：外框 (2,1) 8x5，内容内缩到 (3,2) 6x3
(define s0 (session-blank 40 10))
(define-values (s1 _did vid) (session-add-document s0 "abc" 10 3 #:name "*b*"))
(define sf (float-surface 'b vid #f
                          (float (lambda (_) (area 2 1 8 5)) 5)
                          #f #f #f #f #:border 'window-border))
(define s2 (session-add-surface s1 sf))
(check-equal? (session-pane-inset s2 vid) 1)
(define-values (s3 _new rends _sels) (session-render s2 #f))

(check-equal? (piece-text (cell rends 1 2)) "┌──────┐")   ; 上边
(check-equal? (piece-text (cell rends 5 2)) "└──────┘")   ; 下边
(check-equal? (piece-text (cell rends 2 2)) "│")          ; 左边
(check-equal? (piece-text (cell rends 2 9)) "│")          ; 右边
(check-equal? (piece-text (cell rends 2 3)) "abc")        ; 内容在边框内

;; 无边框：内容直接铺在外框内
(define s4 (session-add-surface s2
             (float-surface 'p vid #f (float (lambda (_) (area 20 1 6 2)) 6)
                            #f #f #f #f)))
(check-equal? (session-pane-inset s4 vid) 1)              ; 仍取到带边框的那个面（按 vid 先命中）
(define s5 (session-remove-surface s4 'b))
(check-equal? (session-pane-inset s5 vid) 0)

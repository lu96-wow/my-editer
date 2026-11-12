#lang racket

;;; Session 正交轴：
;;;   modal   : #f | 'input | modal-placement
;;;   pointer : #f | pointer-drag | pointer-select
;;; 每个轴内部互斥；不同轴可以同时存在。

(require rackunit
         "../editor/host-api.rkt"
         "../features/input/api.rkt")

(define input-seed
  (make-input-state #:panel-id 'status #:status-view 2 #:input-view 5))

(define base (make-app-state #:input input-seed))
(check-true (input-state? (state-input base)))
(check-false (state-placement base))

;; input 与 placement 互斥；placement 退出后 input seed 仍在。
(define s-input (state-with-input base (struct-copy input-state input-seed [active? #t])))
(check-true (editor-input-active? s-input))
(define s-place (state-with-placement s-input 42))
(check-false (state-input s-place))
(check-equal? (state-placement s-place) 42)
(check-true (input-state? (state-input-seed s-place)))
(define s-input2 (state-with-input s-place (state-input-seed s-place)))
(check-equal? (state-placement s-input2) #f)
(check-true (input-state? (state-input s-input2)))

;; drag 与 select-drag 互斥；清掉一个不会误清另一个轴。
(define s-drag (state-with-drag base 'seam))
(check-eq? (state-drag s-drag) 'seam)
(check-false (state-select-drag s-drag))
(define sd (select-drag 'panel 7))
(define s-select (state-with-select-drag s-drag sd))
(check-false (state-drag s-select))
(check-equal? (state-select-drag s-select) sd)
(define s-drag2 (state-with-drag s-select 'seam2))
(check-eq? (state-drag s-drag2) 'seam2)
(check-false (state-select-drag s-drag2))

;; find 是独立轴，不受 modal / pointer 影响。
(define s-find (state-with-find s-drag2 'find-session))
(check-eq? (state-find s-find) 'find-session)
(check-eq? (state-drag s-find) 'seam2)
(check-true (input-state? (state-input s-find)))

(displayln "edit-tui/test/session-axes.rkt: ok")

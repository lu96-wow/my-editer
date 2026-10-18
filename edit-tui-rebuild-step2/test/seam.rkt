#lang racket

;;; edit-tui/test/seam.rkt —— panel 接缝拖动
;;;
;;; 覆盖：press 命中 cut -> seam gesture；move 改 layout dim；release 清 gesture。

(require rackunit
         racket/async-channel
         "../command/key.rkt"
         "../command/mouse.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/input.rkt"
         "../effects/engine.rkt"
         "../projection/geometry.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt"
         "../../core/view/base/rect.rkt")

(define d1 (doc-id 1)) (define d2 (doc-id 2))
(define v1 (view-id 1)) (define v2 (view-id 2))
(define r1 (region-id 1)) (define r2 (region-id 2))
(define engine (make-engine))
(void (engine-create-doc! engine d1 "a.txt" "A\n"))
(void (engine-create-view! engine v1 d1))
(void (engine-create-doc! engine d2 "b.txt" "B\n"))
(void (engine-create-view! engine v2 d2))
(define ws
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws d1 (make-doc-meta "a.txt"))]
         [ws (workspace-add-doc ws d2 (make-doc-meta "b.txt"))]
         [ws (workspace-add-view ws v1 (view-meta d1 (hash)))]
         [ws (workspace-add-view ws v2 (view-meta d2 (hash)))]
         [ws (workspace-add-region ws r1 (region r1 (list (view-member v1)) v1 'editor))]
         [ws (workspace-add-region ws r2 (region r2 (list (view-member v2)) v2 'editor))])
    (struct-copy workspace ws
                 [layout (make-split 'lr
                                     (list (make-leaf r1 (flex 1))
                                           (make-leaf r2 (flex 1)))
                                     (flex 1))])))
(define s0 (state-set-focus (make-state #:workspace ws #:ids (make-id-counter 3 3 3 1)) v1))
(define inbox (make-async-channel))
(define (feed s . evs)
  (transition-state (process-events default-env engine inbox s evs)))

(define area (rect 0 0 80 24))
(define-values (rps0 cuts0) (geometry-solve (workspace-layout ws) area))
(define cut (car cuts0))
(define row (cut-span-lo cut))
(define col (cut-offset cut))
(define w1-before (rect-w (region-panel-content (car rps0))))
(define w2-before (rect-w (region-panel-content (cadr rps0))))

(define s1 (feed s0 (app:mouse-event (mouse 'press 'left) row col)))
(define g (input-gesture (state-input s1)))
(check-not-false g)
(check-eq? (gesture-kind g) 'seam)

(define s2 (feed s1 (app:mouse-event (mouse 'move #f) row (+ col 5))))
(define-values (rps1 _cuts1) (geometry-solve (workspace-layout (state-workspace s2)) area))
(define w1-after (rect-w (region-panel-content (car rps1))))
(define w2-after (rect-w (region-panel-content (cadr rps1))))
(check-true (> w1-after w1-before))
(check-true (< w2-after w2-before))

(define s3 (feed s2 (app:mouse-event (mouse 'release 'left) row (+ col 5))))
(check-false (input-gesture (state-input s3)))
;; release 后 layout 保持
(define-values (rps2 _cuts2) (geometry-solve (workspace-layout (state-workspace s3)) area))
(check-equal? (rect-w (region-panel-content (car rps2))) w1-after)

(displayln "edit-tui seam: ok")

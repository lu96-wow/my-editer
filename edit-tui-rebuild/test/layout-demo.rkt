#lang racket

;;; 布局交互 demo 的 headless 验证：拆分 / 显隐 / 拖缝。
(require rackunit
         "../main.rkt"
         "../demo/interactive.rkt")

(define (visible-ids s)
  (layout-visible-panel-ids (app-state-layout s)))

;;; ---------- filetree 已安装并有内容 ----------
(define synced (sync-ui! demo-state demo-engine))
(define ft (hash-ref (app-state-store synced) 'filetree))
(check-true (> (length (filetree-rows ft)) 0))
(check-true (> (string-length (engine-view-text demo-engine 10)) 0))

;;; ---------- split ----------
(define-values (s1 a1) (step demo-state (key-event (key 'w 'ctrl))))
(check-equal? a1 '())
(check-equal? (app-state-pending s1) (list (key 'w 'ctrl)))
(define-values (s2 a2) (step s1 (key-event (key 'right))))
(check-equal? a2 '())
(check-not-false (memv 100 (visible-ids s2)))
(check-equal? (panel-kind (layout-panel (app-state-layout s2) 100)) 'editor)
(check-equal? (app-state-pending s2) '())

;;; ---------- hide / show filetree ----------
(define-values (s3 a3) (step demo-state (key-event (key 'b 'ctrl))))
(check-equal? a3 '())
(check-false (layout-panel-visible? (app-state-layout s3) 'filetree))
(define-values (s4 a4) (step s3 (key-event (key 'b 'ctrl))))
(check-equal? a4 '())
(check-true (layout-panel-visible? (app-state-layout s4) 'filetree))

;;; ---------- drag filetree seam ----------
(define-values (l-flex ok-flex?) (layout-panel-set-fixed (app-state-layout demo-state) 'filetree 'w #f))
(check-true ok-flex?)
(define s5 (struct-copy app-state demo-state [layout l-flex]))
(define seam (layout-seam-at l-flex (app-state-area s5) 0 30))
(check-not-false seam)
(define seam-x (rect-x (seam-rect seam)))

(define-values (s6 a6) (step s5 (mouse-event 'press 0 seam-x)))
(check-equal? a6 '())
(check-not-false (app-state-drag s6))
(define-values (s7 a7) (step s6 (mouse-event 'move 0 (+ seam-x 5))))
(check-equal? a7 '())
(check-not-false (app-state-drag s7))
(define-values (s8 a8) (step s7 (mouse-event 'release 0 (+ seam-x 5))))
(check-equal? a8 '())
(check-false (app-state-drag s8))

(define widths
  (for/list ([id (in-list (layout-visible-panel-ids (app-state-layout s8)))])
    (define r (hash-ref (layout-panel-rects (app-state-layout s8)
                                            (app-state-area s8))
                        id))
    (cons id (rect-w r))))
;; filetree 从 40 -> 45
(check-equal? (cdr (assoc 'filetree widths)) 35)

(displayln "edit-tui-rebuild/test/layout-demo.rkt: ok")

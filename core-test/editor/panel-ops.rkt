#lang racket

;;; core/editor/panel-ops.rkt —— panel 面操作：纯值变换 + 屏幕格落点。
;;; panel 的 view 槽可以是 #f；所有操作都不得要求 view 存在。

(require rackunit
         "../../core/editor.rkt")

;;; ---------- 值变换（纯）----------
;; 原值不变；view 槽可 #f / 可换回 view；rect / borders / deep / face / weight 逐项可改。
(define pu (make-panel 'pv (rect 5 2 10 4) borders-all #:deep 1 #:face 'pf #:weight 2))
(define pu-empty (panel-with-view pu #f))
(check-true (panel-empty? pu-empty))
(check-equal? (panel-view pu) 'pv)                 ; 原 panel 不被改
(check-equal? (panel-rect pu-empty) (rect 5 2 10 4))
(check-equal? (panel-borders pu-empty) borders-all)
(check-equal? (panel-deep pu-empty) 1)
(check-equal? (panel-face pu-empty) 'pf)
(check-equal? (panel-weight pu-empty) 2)
(check-equal? (panel-view (panel-with-view pu-empty 'new)) 'new)

(check-equal? (panel-rect (panel-with-rect pu (rect 1 1 3 2))) (rect 1 1 3 2))
(check-equal? (panel-rect (panel-shift pu 3 -1)) (rect 8 1 10 4))
(check-equal? (panel-rect (panel-shift pu -5 2)) (rect 0 4 10 4))
(check-equal? (panel-rect (panel-resize pu 6 2)) (rect 5 2 6 2))
(check-equal? (panel-rect (panel-resize pu -1 -2)) (rect 5 2 0 0))
(check-equal? (panel-borders (panel-with-borders pu '(left))) '(left))
(check-equal? (panel-deep (panel-with-deep pu 9)) 9)
(check-equal? (panel-face (panel-with-face pu #f)) #f)
(check-equal? (panel-weight (panel-with-weight pu 0)) 0)
(check-equal? (panel-view pu) 'pv)                 ; 所有更新都不改原值

;;; ---------- 落点：空面板 / 正常面板 ----------
(define pe (empty-panel (rect 0 0 4 3) borders-all))
(check-false (panel-set-point! pe 1 1))            ; 空面板 → #f，不动

(define b (make-buffer "abc\ndef"))
(define v (buffer-add-view! b))
(define p (make-panel v (rect 0 0 6 4) borders-all))
(panels-sync! (list p))
(check-true (panel-set-point! p 1 1))              ; 内容原点 (1,1) → 文档 (0,0)
(check-equal? (view-point v) (point 0 0))
(check-true (panel-set-point! p 2 2))              ; → 文档 (1,1)
(check-equal? (view-point v) (point 1 1))
(check-false (panel-set-point! p 0 0))             ; 边框上 → #f，不动
(check-equal? (view-point v) (point 1 1))

(displayln "editor/panel-ops.rkt: ok")

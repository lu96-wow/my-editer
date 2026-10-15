#lang racket

;;; core/editor/sync.rkt —— panel.rect → view.viewport 尺寸（唯一尺寸写入口）。
(require rackunit
         "../../core/editor.rkt")

(define b (make-buffer "hello\nworld"))
(define v (buffer-add-view! b 3 3))          ; 初始占位，真实尺寸由 panel 决定

;; 内容区 = 外框按存在的边各内缩 1
(panels-sync! (list (make-panel v (rect 0 0 10 4) borders-all)))
(check-equal? (view-width v) 8)
(check-equal? (view-height v) 2)

;; 无边框：内容区 = 外框
(panel-sync! (make-panel v (rect 0 0 5 3) borders-none))
(check-equal? (view-width v) 5)
(check-equal? (view-height v) 3)

;; 外框太小 → viewport 最小夹到 1
(panel-sync! (make-panel v (rect 0 0 1 1) borders-all))
(check-equal? (view-width v) 1)
(check-equal? (view-height v) 1)

;; 空面板没有 view，同步是 no-op（不崩）
(panel-sync! (empty-panel (rect 0 0 4 4) borders-all))

;; buffer-add-panel!：建 view + panel + 立即 sync，并登记进 buffer.views
(define b2 (make-buffer "abcdef\ngh"))
(define p (buffer-add-panel! b2 (rect 0 0 6 4) borders-none))
(check-equal? (view-width (panel-view p)) 6)
(check-equal? (view-height (panel-view p)) 4)
(check-not-false (memq (panel-view p) (buffer-views b2)))

(displayln "editor/sync.rkt: ok")

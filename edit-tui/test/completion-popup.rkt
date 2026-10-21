#lang racket

;;; 补全弹窗几何：整个编辑区、避开光标行、尺寸自适应。

(require rackunit
         "../main.rkt"
         "../demo/completion-popup.rkt")

(define area (rect 0 0 80 24))
(define editor (rect 10 2 60 18))

;; 光标上方空间足够：放在下方，不覆盖光标行。
(define p1 (popup-geometry area editor 20 5 6 12))
(check-not-false p1)
(define r1 (popup-layout-rect p1))
(check-true (>= (rect-y r1) 6))
(check-equal? (popup-layout-inner-width p1) (- (rect-w r1) 2))
(check-equal? (popup-layout-inner-height p1) 6)
(check-true (<= (rect-right r1) (rect-right editor)))
(check-true (<= (rect-bottom r1) (rect-bottom editor)))

;; 光标靠近底部：翻到上方，底边不进入光标行。
(define p2 (popup-geometry area editor 20 18 6 12))
(check-not-false p2)
(define r2 (popup-layout-rect p2))
(check-true (<= (rect-bottom r2) 18))

;; 宽度受编辑区限制，而不是固定值。
(define p3 (popup-geometry area editor 20 5 2 100))
(check-not-false p3)
(define r3 (popup-layout-rect p3))
(check-equal? (rect-w r3) (rect-w editor))

;; 编辑区太小 / 没有候选：不生成弹窗。
(check-false (popup-geometry area (rect 10 2 2 10) 10 3 3 4))
(check-false (popup-geometry area editor 20 5 0 4))

;; 内容行没有 ">" 标记，并补齐到 inner-width。
(define lines (completion-lines (list "first" "filter") 20))
(check-equal? (length lines) 2)
(check-false (string-contains? (car lines) ">"))
(check-equal? (string-length (car lines)) 20)
(check-equal? (string-trim (car lines)) "first")

(displayln "edit-tui-rebuild/test/completion-popup.rkt: ok")

#lang racket

;;; edit3-test/border.rkt —— 分隔线交点（纯装饰层）
;;;
;;; 重点回归：四窗相交的十字路口格，四个正交邻居都是缝格、没有窗口，
;;; 早期 adjacent-bordered? 因看不到对角窗口而漏画 → 路口空白。
;;; 修复后应得到 ┼ / ┘ 等正确字形。

(require rackunit
         racket/list
         "../../edit3/core/state.rkt"
         "../../edit3/core/layout.rkt"
         "../../edit3/core/border.rkt")

(define (mk axis b g s child) (item b g s (axis-min child axis) child))
(define (t wid border) (tile wid 'v (cons 2 2) border))
(define SZ (cons 21 11))
(define B 'window-border)

;; 2×2：root h-split，两列为 v-split —— 十字路口的缝格在 root 竖缝上
(define (grid2x2 border-of)
  (tiling (split 'h
                 (list (mk 'h 1 1 1 (split 'v (list (mk 'v 1 1 1 (t 'tl (border-of 'tl)))
                                                    (mk 'v 1 1 1 (t 'bl (border-of 'bl))))))
                       (mk 'h 1 1 1 (split 'v (list (mk 'v 1 1 1 (t 'tr (border-of 'tr)))
                                                    (mk 'v 1 1 1 (t 'br (border-of 'br))))))))))

(define (runs tl) (border-runs (make-state #:tiling tl) (layout tl '() SZ)))
(define (has? tl ch)
  (for/or ([r (in-list (runs tl))]) (regexp-match? (regexp (string ch)) (list-ref r 2))))

;; 四窗全有边框 → 路口是 ┼
(check-true (has? (grid2x2 (lambda (_) B)) #\┼))
;; 只有 tl 有边框 → 竖缝向上、横缝向左，路口收成 ┘（连上、连左）
(check-true (has? (grid2x2 (lambda (w) (and (eq? w 'tl) B))) #\┘))
;; 全无边框 → 不画任何分隔线
(check-equal? (runs (grid2x2 (lambda (_) #f))) '())

(displayln "edit3/border.rkt: all tests passed")

#lang racket

;;; 由 edit-tui/base/face.rkt 的测试外移而来（edit-tui 只留实现）。
(require rackunit
         "../../edit-tui/base/face.rkt")

;; 构造 / 读
(define f (face 'kw 'bg1 '(bold)))
(check-equal? (face-fg f) 'kw)
(check-equal? (face-bg f) 'bg1)
(check-equal? (face-attrs f) '(bold))
;; 写：#f 也收
(check-equal? (face-set-bg #f 'depth-2) (face #f 'depth-2 '()))
(check-equal? (face-set-fg (face 'a 'b '()) 'c) (face 'c 'b '()))
;; 只改 bg，fg 保留（插件读改写）
(check-equal? (face-set-bg (face 'kw #f '()) 'depth-2) (face 'kw 'depth-2 '()))
;; attrs 幂等
(check-equal? (face-add-attr (face-add-attr #f 'bold) 'bold) (face #f #f '(bold)))
(check-equal? (face-remove-attr (face #f #f '(bold italic)) 'bold)
              (face #f #f '(italic)))
;; 不是 pair（overlay 编码可区分）
(check-false (pair? (face 'a 'b '())))

(displayln "edit-tui/base/face.rkt: ok")

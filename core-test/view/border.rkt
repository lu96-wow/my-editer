#lang racket

;;; 由 core/view/border.rkt 的测试外移而来（core 只留实现）。
(require rackunit
         "../../core/view/border.rkt"
         "../../core/view/panel.rkt"
         "../../core/view/base/rect.rkt")

(define (texts panels) (map (lambda (r) (list-ref r 2)) (panels->border-runs panels)))
(define (has? panels ch)
  (for/or ([t (in-list (texts panels))]) (regexp-match? (regexp (string ch)) t)))
(define (mk v x y w h b #:deep [d 0]) (make-panel v (rect x y w h) b #:deep d))

;; 单框：四角
(define one (list (mk 'a 0 0 4 3 borders-all)))
(check-true (has? one #\┌)) (check-true (has? one #\┐))
(check-true (has? one #\└)) (check-true (has? one #\┘))

;; 共线 + 垂直相交：A 缺底边，B 在下接上 → ├
(check-true (has? (list (mk 'a 0 0 5 3 '(up left right))
                        (mk 'b 0 3 5 3 borders-all)) #\├))

;; 平行相邻不连
(check-false (has? (list (mk 'a 0 0 5 3 borders-all) (mk 'b 5 0 5 3 borders-all)) #\├))
(check-false (has? (list (mk 'a 0 0 5 3 borders-all) (mk 'b 5 0 5 3 borders-all)) #\┤))

;; 遮挡：高 deep 浮窗盖住低层边框格 → 该格不收（无悬空臂）
;; 低层横线 row2 cols0..7（face lo-face），浮窗 (2,2,4,2) 盖住 row2 cols2..5
(define occl (list (make-panel 'lo (rect 0 2 8 1) '(up) #:face 'lo-face)
                   (make-panel 'hi (rect 2 2 4 2) borders-all #:deep 10 #:face 'hi-face)))
(define (lo-run-covers? r)
  (and (eq? (list-ref r 3) 'lo-face)
       (= (car r) 2) (<= (cadr r) 2)
       (> (+ (cadr r) (string-length (caddr r))) 2)))
(check-false (for/or ([r (in-list (panels->border-runs occl))]) (lo-run-covers? r)))
;; 未被盖住的左端仍在
(check-true (for/or ([r (in-list (panels->border-runs occl))])
              (and (eq? (list-ref r 3) 'lo-face) (= (car r) 2) (= (cadr r) 0))))

;; weight：同 deep 时边框 face 由 big weight 决定（默认 0 → 列表靠后）
(define (cell-face ps r c) (list-ref (hash-ref (panels->border-cells ps) (cons r c)) 1))
(define p0 (make-panel 'a (rect 0 0 10 6) borders-all #:face 'a-face #:weight 0))
(define p1 (make-panel 'b (rect 9 0 10 6) borders-all #:face 'b-face #:weight 1))
(check-equal? (cell-face (list p0 p1) 1 9) 'b-face)        ; weight 1 赢
(check-equal? (cell-face (list p1 p0) 1 9) 'b-face)        ; 与列表序无关
(define p0* (make-panel 'a (rect 0 0 10 6) borders-all #:face 'a-face #:weight 2))
(check-equal? (cell-face (list p0* p1) 1 9) 'a-face)       ; 更大的 weight 赢
;; deep 仍然压过 weight：高 deep 浮窗（weight 0）盖住 weight 高的低层
(define f (make-panel 'f (rect 9 2 5 2) borders-all #:deep 10 #:face 'f-face #:weight 0))
(check-equal? (cell-face (list p0* f) 3 9) 'f-face)

(displayln "core/view/border.rkt: ok")

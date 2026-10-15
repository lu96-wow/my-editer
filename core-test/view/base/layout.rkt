#lang racket

;; 由 core/view/base/layout.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core/view/base/layout.rkt"
       "../../../core/text/base/track.rkt"
       "../../../core/text/base/line.rkt"
       "../../../core/text/base/point.rkt"
       "../../../core/text/base/width.rkt")

;; clip：一行一段
(check-equal? (segments-of-line "abcd" 10 'clip) '((0 . 4)))
;; wrap：折行段
(check-equal? (segments-of-line "aaaa中中中" 5 'wrap) '((0 . 4) (4 . 8) (8 . 10)))

;; wrap-segments（显示宽切段）：宽字符不拆半；空行一段；末段满宽补空段
(check-equal? (wrap-segments "aaaa中中中" 5) '((0 . 4) (4 . 8) (8 . 10)))
(check-equal? (wrap-segments "中" 1) '((0 . 2)))
(check-equal? (wrap-segments "" 5) '((0 . 0)))
(check-equal? (wrap-segments "aaaa" 4) '((0 . 4) (4 . 4)))
(check-equal? (wrap-segments "aaa" 4) '((0 . 3)))

;; vrows clip：每屏行 = 一行
(define tc (track-of-list (list "abc" "def" "ghi")))
(check-equal? (map (lambda (v) (list (vrow-line v) (vrow-start-column v) (vrow-end-column v)))
                   (vector->list (vrows tc 0 0 1 5 3 'clip)))
              '((0 1 6) (1 1 6) (2 1 6)))     ; end = left+width（render 会按行长裁）

;; vrows wrap：一行折成多屏幕行
(define tw (track-of-list (list "aaaaa" "b")))
(check-equal? (map (lambda (v) (list (vrow-line v) (vrow-start-column v) (vrow-end-column v)))
                   (vector->list (vrows tw 0 0 0 4 3 'wrap)))
              '((0 0 4) (0 4 5) (1 0 1)))

;; 视觉行移动
(define tw2 (track-of-list (list "aaaaa" "b")))
;; wrap：从 (0,0) 下移 → 同行第 2 段首列
(check-equal? (vrow-move tw2 4 'wrap (point 0 0) +1) (point 0 4))
;; 再下移 → 下一行
(check-equal? (vrow-move tw2 4 'wrap (point 0 4) +1) (point 1 0))
;; clip：按行下移，保持显示列
(define tc2 (track-of-list (list "abcdef" "ab")))
(check-equal? (vrow-move tc2 10 'clip (point 0 5) +1) (point 1 2))

(displayln "layout.rkt: all tests passed")

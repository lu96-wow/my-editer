#lang racket

;; 与 core/view/overlay.rkt 对应的外部测试。
(require rackunit
         "../../core/view/overlay.rkt"
         "../../core/view/base/screen.rkt"
         "../../core/view/base/viewport.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/track.rkt")

(define bd (document-open "abc\ndef"))
(define t (document-text bd))

;; 无行号
(define vp (viewport-open 10 2))
(define vrs (viewport-vrows t vp))
(check-equal? (overlay-cursors t vp vrs (selections-one (caret (point 0 1))))
              (list (cursor 0 1 #t)))
;; 不可见（视口只有 1 行，点在下一行）
(define vp1 (viewport-open 10 1))
(check-equal? (overlay-cursors t vp1 (viewport-vrows t vp1) (selections-one (caret (point 1 1)))) '())
(check-equal? (overlay-regions t vp vrs (selections-one (selection (point 0 0) (point 0 2))) 0)
              (list (region 0 0 2 #t)))
(check-equal? (overlay-regions t vp vrs (selections-one (caret (point 0 1))) 0) '())  ; 空选区无 region

;; 多选区：primary 标记 + 跨行切段
(define ss (selections-of (list (selection (point 0 0) (point 0 2)) (caret (point 1 1))) 0))
(check-equal? (overlay-cursors t vp vrs ss) (list (cursor 0 2 #t) (cursor 1 1 #f)))
(check-equal? (overlay-regions t vp vrs ss 0) (list (region 0 0 2 #t)))
(check-equal? (overlay-regions t vp vrs (selections-one (selection (point 0 1) (point 1 2))) 0)
              (list (region 0 1 3 #t) (region 1 0 2 #t)))

;; 行号栏偏移（gutter=2）
(define vpn (viewport-open 10 2 'clip #t))
(define vrsn (viewport-vrows t vpn))
(check-equal? (overlay-cursors t vpn vrsn (selections-one (caret (point 0 1))))
              (list (cursor 0 3 #t)))
(check-equal? (overlay-regions t vpn vrsn (selections-one (selection (point 0 0) (point 0 2))) 2)
              (list (region 0 2 4 #t)))

(displayln "overlay.rkt: all tests passed")

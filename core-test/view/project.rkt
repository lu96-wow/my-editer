#lang racket

;; 与 core/view/project.rkt 对应的外部测试。
(require rackunit
         "../../core/view/project.rkt"
         "../../core/view/base/screen.rkt"
         "../../core/view/base/viewport.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/track.rkt")

(define bd (document-open "abc\ndef"))

;; 无行号：project-row 给内容 run（正文坐标，不含栏）
(define vp (viewport-open 6 2 'clip))
(define vrs (viewport-vrows (document-text bd) vp))
(check-equal? (map (lambda (r) (list (run-column r) (run-text r) (run-face r)))
                   (project-row bd (vector-ref vrs 0)))
              '((0 "abc" #f)))
(define-values (rows g) (project bd vp vrs))
(check-equal? g 0)
(check-equal? (map run-text (vector-ref rows 0)) '("abc"))

;; 行号栏：rows 含行号 run，正文右移栏宽
(define vpn (viewport-open 6 2 'clip #t))
(define vrsn (viewport-vrows (document-text bd) vpn))
(define-values (rowsn gn) (project bd vpn vrsn))
(check-equal? gn 2)
(check-equal? (map (lambda (r) (list (run-column r) (run-text r))) (vector-ref rowsn 0))
              '((0 "1 ") (2 "abc")))
(check-equal? (map (lambda (r) (list (run-column r) (run-text r))) (vector-ref rowsn 1))
              '((0 "2 ") (2 "def")))

;; 文末之外的行：无行号、无内容
(define vpb (viewport-open 6 4 'clip #t))
(define-values (rowsb _gb) (project bd vpb (viewport-vrows (document-text bd) vpb)))
(check-equal? (vector-ref rowsb 2) '())

;; gutter-text
(check-equal? (gutter-text 0 2) "1 ")
(check-equal? (gutter-text 11 4) " 12 ")

(displayln "project.rkt: all tests passed")

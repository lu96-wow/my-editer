#lang racket

;;; core/editor/attributes.rkt —— 端口（face / readonly）写回：就地改盒、惰性释放、边界 no-op。
(require rackunit
         "../../core/editor.rkt"
         "../../core/text/document.rkt"
         (only-in "../../core/editor/state.rkt" buffer-document))

(define b (make-buffer "abc\ndef"))

;; ---------- face：区间 / 格 / 行 ----------
(buffer-face-range! b (range (point 0 1) (point 0 3)) 'kw)
(check-equal? (buffer-face-at b 0 1) 'kw)
(check-false (buffer-face-at b 0 0))
(buffer-face-cell! b 0 0 'head)
(check-equal? (buffer-face-at b 0 0) 'head)
(buffer-face-line! b 1 'line)
(check-equal? (buffer-face-row b 1) (vector 'line 'line 'line))

;; 边界：行尾列（== 行长）不是格 → no-op；空区间 no-op
(buffer-face-cell! b 0 3 'x)
(check-false (buffer-face-at b 0 3))
(buffer-face-range! b (range (point 0 1) (point 0 1)) 'x)
(check-equal? (buffer-face-at b 0 0) 'head)

;; batch（坐标）/ range-batch
(buffer-face-batch! b (list (list 0 0 0 1 'a) (list 0 2 0 3 'c)))
(check-equal? (buffer-face-row b 0) (vector 'a 'kw 'c))
(buffer-face-range-batch! b (list (list (range (point 1 0) (point 1 2)) 'r)))
(check-equal? (buffer-face-row b 1) (vector 'r 'r 'line))

;; ---------- 惰性：整篇设默认 → O(1) 释放回 #f ----------
(buffer-face-all! b 'all)
(check-equal? (buffer-face-at b 0 0) 'all)
(buffer-face-all! b #f)
(check-false (document-face (buffer-document b)))
(check-false (buffer-face-at b 0 0))

;; ---------- readonly ----------
(buffer-readonly-range! b (range (point 0 0) (point 0 2)) #t)
(check-true (buffer-readonly-at? b 0 0))
(buffer-readonly-cell! b 0 2 #t)
(check-true (buffer-readonly-at? b 0 2))
(buffer-readonly-line! b 1 #t)
(check-equal? (buffer-readonly-row b 1) (vector #t #t #t))
(buffer-readonly-all! b #f)
(check-false (document-readonly (buffer-document b)))
(check-false (buffer-readonly-at? b 0 0))

;; 区间查询（与只读成对）
(buffer-readonly-range! b (range (point 0 1) (point 0 3)) #t)
(check-true (buffer-readonly-any? b 0 0 0 3))
(check-false (buffer-readonly-any? b 1 0 1 3))
(check-false (buffer-editable? b 0 1 0 2))   ; 区间含只读格
(check-true (buffer-editable? b 0 0 0 1))

(displayln "editor/attributes.rkt: ok")

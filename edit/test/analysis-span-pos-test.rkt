#lang racket

;;; edit/test/analysis-span-pos-test.rkt —— 分析工具：坐标 / 数据形状（headless）
;;;
;;;   raco test edit/test/analysis-span-pos-test.rkt

(require rackunit
         "../plugin/analysis/tools/span.rkt"
         "../plugin/analysis/tools/pos.rkt")

;;; ---------- span ----------

(check-true (span-empty? (span 2 2)))
(check-equal? (span-length (span 3 7)) 4)
(check-true (span-contains? (span 3 7) 3))
(check-true (span-contains? (span 3 7) 6))
(check-false (span-contains? (span 3 7) 7))
(check-false (span-contains? (span 3 7) 2))
(check-true (span-intersect? (span 0 5) (span 4 9)))
(check-false (span-intersect? (span 0 5) (span 5 9)))
(check-equal? (span-normalize (span 9 4)) (span 4 9))

;;; ---------- pos ----------

(define (idx s) (make-line-index s))
(define (lco s off)
  (call-with-values (lambda () (offset->line/col (idx s) off)) list))

(check-equal? (lco "" 0) '(0 0))
(check-equal? (lco "abc" 2) '(0 2))
(check-equal? (lco "a\nb" 2) '(1 0))
(check-equal? (lco "a\n" 2) '(1 0))
(check-equal? (lco "中\n文" 1) '(0 1))          ; 字符偏移（非字节）
(check-equal? (lco "中\n文" 2) '(1 0))

;; 行度量
(define i1 (idx "a\nbb\n"))
(check-equal? (line-count i1) 3)
(check-equal? (line-start i1 1) 2)
(check-equal? (line-end i1 1) 4)
(check-equal? (line-length i1 1) 2)
(check-equal? (line-count (idx "")) 1)
(check-equal? (line-length (idx "a\n") 1) 0)

;; 每个合法偏移 roundtrip
(for ([s (in-list '("" "abc" "a\nb" "a\n" "a\nbb\nccc" "中\n文\n" "\n\n"))])
  (define i (idx s))
  (for ([off (in-range 0 (add1 (string-length s)))])
    (define-values (l c) (offset->line/col i off))
    (check-equal? (line/col->offset i l c) off (format "roundtrip ~s @~a" s off))))

;; clamp（越界偏移 / 行列）
(check-equal? (offset->line (idx "ab") -5) 0)
(check-equal? (offset->line (idx "ab") 99) 0)
(check-equal? (offset->col (idx "ab") 99) 2)
(check-equal? (line/col->offset (idx "a\nb") 99 99) 3)
(check-equal? (line/col->offset (idx "a\nb") -1 -1) 0)

;; (line,col) 与 offset 的对应（含行首 / 行尾）
(check-equal? (line/col->offset (idx "a\nbb\n") 1 2) 4)
(check-equal? (line/col->offset (idx "a\nbb\n") 2 0) 5)

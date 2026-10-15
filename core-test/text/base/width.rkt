#lang racket

;; 由 core/text/base/width.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core/text/base/width.rkt")

(check-equal? (char-display-width #\a) 1)
(check-equal? (char-display-width #\中) 2)
(check-equal? (char-display-width #\😀) 2)
(check-equal? (char-display-width (integer->char #x0301)) 0)   ; 组合重音
(check-equal? (char-display-width (integer->char #x200D)) 0)   ; ZWJ

(check-equal? (string-display-width "") 0)
(check-equal? (string-display-width "中文") 4)
(check-equal? (string-display-width "e\u0301") 1)

;; 字符索引 ↔ 显示列（宽字符 2 列）
(define s "a中b")
(for ([i (in-range 0 4)])
  (check-equal? (display-column->index s (index->display-column s i)) i))
(check-equal? (index->display-column s 0) 0)
(check-equal? (index->display-column s 2) 3)
(check-equal? (index->display-column s 3) 4)     ; 索引 = 长度 → 总列数
(check-equal? (display-column->index s 2) 1)    ; 宽字符右半格命中同一字符
(check-equal? (display-column->index s 99) 3)   ; 越界 → 字符串长度

;; 吸附
(check-equal? (snap-display-column-forward "中a中" 1) 2)
(check-equal? (snap-display-column-forward "中a中" 3) 3)
(check-equal? (snap-display-column-forward "中a中" 99) 5)
(check-equal? (snap-display-column-forward s -1) 0)

(displayln "width.rkt: all tests passed")

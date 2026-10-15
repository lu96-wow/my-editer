#lang racket

;; 由 core/view/base/screen.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../../core/view/base/screen.rkt"
       "../../../core/text/base/width.rkt")

(define s (screen 10 2
                  (vector (list (run 0 "ab" 'bold) (run 2 "中" 'kw)) '())
                  (list (cursor 0 3 #t))
                  (list (region 0 0 2 #f))))
(check-equal? (screen-row s 0) (list (run 0 "ab" 'bold) (run 2 "中" 'kw)))
(check-equal? (screen->string s) "ab中\n")
(check-equal? (map cursor-column (screen-cursors s)) '(3))
(check-equal? (map region-end-column (screen-regions s)) '(2))
(check-exn exn:fail? (lambda () (screen-row s 9)))

;; run 间的空隙补空格；行尾不补
(define sg (screen 6 1 (vector (list (run 0 "a" 'f) (run 3 "b" 'f))) '() '()))
(check-equal? (screen->string sg) "a  b")

(displayln "screen.rkt: all tests passed")

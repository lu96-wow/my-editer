#lang racket

;;; 测试用 editor fixture：一个无 path、名为 test.rkt 的 Racket buffer。
;;; 生产入口 make-editor-app 不再创建默认初始 resource。

(require "../host/final.rkt")

(provide make-test-editor)

(define sample-text
  (string-append "#lang racket\n"
                 "\n"
                 "(define (main xs)\n"
                 "  (map add1 xs))\n"))

(define (make-test-editor)
  (make-editor-app #:initial-text sample-text
                   #:initial-name "test.rkt"
                   #:initial-resource? #t))

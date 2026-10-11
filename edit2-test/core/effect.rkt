#lang racket

;;; edit2-test/effect.rkt —— edit2/effect.rkt 的外部测试

(require rackunit
         "../../edit2/core/effect.rkt")

(check-true (effect? (quit-effect)))
(check-true (effect? (open-file "/tmp/x")))
(check-true (effect? (save-file "/tmp/x" "hi")))
(check-false (effect? 'nope))

(displayln "edit2/effect.rkt: all tests passed")

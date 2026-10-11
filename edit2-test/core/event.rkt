#lang racket

;;; edit2-test/event.rkt —— edit2/event.rkt 的外部测试

(require rackunit
         "../../edit2/core/event.rkt")

(check-true (key-is? (key-event 'a '()) 'a))
(check-true (key-is? (key-event 'a '(alt ctrl)) 'a '(ctrl alt)))
(check-false (key-is? (key-event 'a '(ctrl)) 'a))
(check-true ((on-key 'a) #f (key-event 'a '())))
(check-true ((on-cursor 'press 'left) #f (cursor-event 'press 'left 3 4)))
(check-false ((on-cursor 'scroll) #f (cursor-event 'press 'left 3 4)))
(check-true ((on-cursor 'scroll) #f (cursor-event 'scroll 'up 3 4)))

(displayln "edit2/event.rkt: all tests passed")

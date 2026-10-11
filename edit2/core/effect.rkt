#lang racket

;;; edit2/effect.rkt —— Effect ADT（一次性 IO）
;;;
;;; Effect 只承载一次性副作用；后台计算走 jobs（见 step.rkt）。
;;; Effect 是数据，只在 runtime 边缘被 perform! 解释。

(provide
 (struct-out open-file)
 (struct-out save-file)
 (struct-out quit-effect)
 (struct-out log-effect)
 effect?)

(struct open-file (path) #:transparent)
(struct save-file (path text) #:transparent)
(struct quit-effect () #:transparent)
(struct log-effect (msg) #:transparent)

(define (effect? x)
  (or (open-file? x) (save-file? x) (quit-effect? x) (log-effect? x)))


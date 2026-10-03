#lang racket

;;; lab/main.rkt —— TUI 入口：造 display → 跑 driver 主循环

(require "driver.rkt"
         "io/tui.rkt"
         "output.rkt")

(define (run!)
  (define disp (make-tui-display))
  (define-values (rows cols) (display-size disp))
  (define app-box (box (app-open disp rows cols)))
  (run-tui! (lambda () (set-box! app-box (app-draw (unbox app-box))))
            (lambda (in) (set-box! app-box (app-input (unbox app-box) in)))
            (lambda () (app-quit? (unbox app-box)))
            #:display disp))

(module+ main (run!))

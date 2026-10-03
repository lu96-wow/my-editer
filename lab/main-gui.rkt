#lang racket

;;; lab/main-gui.rkt —— racket/gui 入口：同一 driver，只换 display
;;;
;;; 与 main.rkt 的差别仅在「怎么造 display、怎么驱动事件」：
;;; gui 是回调式（on-input 直接喂 app-input），tui 是阻塞式（run-tui! 循环）。

(require racket/gui/base
         "driver.rkt"
         "io/gui.rkt"
         "output.rkt")

(define (run!)
  (define app-box (box #f))
  (define disp
    (make-gui-display
     #:on-input (lambda (in)
                  (when (unbox app-box)
                    (set-box! app-box (app-input (unbox app-box) in))))))
  (define-values (rows cols) (display-size disp))
  (set-box! app-box (app-draw (app-open disp rows cols)))
  (display-init! disp))

(module+ main (run!))

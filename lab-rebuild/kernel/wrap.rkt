#lang racket

;;; lab-rebuild/kernel/wrap.rkt —— 纯文本折行（浮窗 / 文档共用）。

(require racket/string)

(provide wrap-line wrap-lines)

;; 单行按宽度 w 折行：尽量在空格断，断不了就硬断。
(define (wrap-line s w)
  (let loop ([s s] [acc '()])
    (cond
      [(<= (string-length s) w) (reverse (cons s acc))]
      [else
       (define cut
         (or (for/first ([i (in-range (sub1 w) 0 -1)]
                         #:when (char=? (string-ref s i) #\space))
               i)
             w))
       (loop (string-trim (substring s cut)) (cons (substring s 0 cut) acc))])))

(define (wrap-lines text w)
  (append* (for/list ([l (in-list (string-split text "\n"))]) (wrap-line l w))))

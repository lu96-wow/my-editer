#lang racket

;;; lab-test/io/headless.rkt —— 测试用 display：把 span 记下来，不画任何东西
;;;
;;; 用来在无终端 / 无窗口环境下验证「open → 编辑 → 渲染 → 呈现」整条链路。

(require "../../lab/output.rkt")

(provide make-headless-display)

;; → (values display spans-box)
;; spans-box 存最近一次 put! 的 span 列表（新的在前）；clear! 清空。
(define (make-headless-display [rows 24] [cols 80])
  (define spans (box '()))
  (values
   (make-display
    #:init! void                                           ; init!
    #:exit! void                                           ; exit!
    #:size (lambda () (values rows cols))                  ; size
    #:clear! (lambda () (set-box! spans '()))              ; clear!
    #:put! (lambda (row col text st)                       ; put!
             (set-box! spans (cons (span row col text st) (unbox spans))))
    #:flush! void)                                         ; flush!
   spans))

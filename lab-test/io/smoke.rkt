#lang racket

;;; lab-test/io/smoke.rkt —— IO 抽象冒烟：model → screen → span → headless display

(require rackunit
         "../../lab/model/session.rkt"
         "../../lab/model/render.rkt"
         "../../lab/output.rkt"
         "../../lab/theme.rkt"
         "../../lab/io/headless.rkt"
         "../../core/view/base/screen.rkt")

(define s0 (session-open "abc\ndef" 40 10 "d0"))
(define scr (session-render s0))

(define-values (disp spans) (make-headless-display 10 40))
(void (present! disp #f scr attr->style))

(define texts (for/list ([sp (in-list (unbox spans))]) (span-text sp)))

;; 文档正文投影出来；光标在 (0,0) → "abc" 切成光标段 "a" + 正文段 "bc"。
(check-not-false (member "bc" texts))
(check-not-false (member "def" texts))
;; 底部状态栏
(check-not-false (member "lab" texts))

;; 光标段带反显样式
(check-true
 (for/or ([sp (in-list (unbox spans))]
          #:when (and (equal? (span-text sp) "a") (style-reverse? (span-style sp))))
   #t))

;; 增量：同一帧再 present! 不产生新 span（也不清屏）。
(define n (length (unbox spans)))
(void (present! disp scr scr attr->style))
(check-equal? (length (unbox spans)) n)

;; 尺寸变化 → 全量（clear! 清空后重画）。
(void (present! disp scr (session-render (session-resize s0 10 38)) attr->style))
(check-true (pair? (unbox spans)))

(printf "ALL IO SMOKE OK\n")

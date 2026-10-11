#lang racket

;;; edit2-test/render.rkt —— edit2/render.rkt 的外部测试（端到端：boot → layout → render）

(require rackunit
         "../../edit2/core/render.rkt"
         "../../edit2/core/step.rkt"
         "../../edit2/core/event.rkt"
         "../../edit2/core/route.rkt"
         "../../edit2/core/layout.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/adapter.rkt")

(define st (boot "abc" "t" 60 5))
(define ps (layout (state-layout st) (cons 60 5)))
(define-values (screen rends sels) (render st ps (cons 60 5) #f))
(define text
  (apply string-append
         (for/list ([p (in-list (sort (append rends sels) <
                                     #:key (lambda (p) (+ (* (piece-row p) 1000)
                                                          (piece-column p)))) )])
           (piece-text p))))
(check-true (regexp-match? #rx"abc" text))

;; 分屏后两个编辑窗格 + 树 + 状态行都渲染
(define st2 (call-with-values (lambda () (step (app-routes) (ctx (cons 60 5) '())
                                                        st (key-event 'w '(ctrl))))
                              (lambda (s e) s)))
(define ps2 (layout (state-layout st2) (cons 60 5)))
(check-equal? (length (filter (lambda (p) (not (placement-float? p))) ps2)) 4)

(displayln "edit2/render.rkt: all tests passed")

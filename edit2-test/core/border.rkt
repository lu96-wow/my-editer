#lang racket

;;; edit2-test/border.rkt —— 窗口边框（原子格组合 + 合并 + 开关）

(require rackunit
         racket/list
         "../../edit2/core/border.rkt"
         "../../edit2/core/layout.rkt"
         "../../edit2/core/state.rkt"
         "../../edit2/core/theme.rkt")

;; 两个都有边框的左右窗：共享一条竖线（中间列只出现一次），顶部 T 字
(define t (split 'h (list (cons 'flex (pane 'w1 'a 'window-border))
                          (cons 'flex (pane 'w2 'b 'window-border)))))
(define ps (layout t (cons 20 5)))
(define-values (content runs) (border-plan t ps))

(define (c-rect cps w)
  (placement-rect (findf (lambda (p) (eqv? w (placement-wid p))) cps)))
(define (runs-at runs r)
  (sort (filter (lambda (b) (= r (border-run-row b))) runs) < #:key border-run-col))

;; 内容内缩：左窗四边 1；右窗左边被抑制（共享线归左窗右边）
(check-equal? (c-rect content 'w1) (rect 1 1 8 3))
(check-equal? (c-rect content 'w2) (rect 10 1 9 3))

;; 顶边：一整条 20 格，第 9 格是 T 字交点
(define top (findf (lambda (b) (= 0 (border-run-row b))) runs))
(check-equal? (border-run-col top) 0)
(check-equal? (string-length (border-run-text top)) 20)
(check-equal? (string-ref (border-run-text top) 9) #\┬)   ; ├ ┤ ┬ ┴ ┼
(check-equal? (string-ref (border-run-text top) 0) #\┌)
(check-equal? (string-ref (border-run-text top) 19) #\┐)

;; 中间行：三条竖线（左窗左、共享、右窗右），共享线只画一次
(define mid (runs-at runs 1))
(check-equal? (map border-run-col mid) '(0 9 19))
(check-equal? (map border-run-text mid) '("│" "│" "│"))

;; 关掉左窗边框：共享线变成右窗自己的左边（col 10），左窗不再有边
(define t2 (layout-set-pane-border t 'w1 #f))
(define-values (content2 runs2) (border-plan t2 ps))
(check-equal? (c-rect content2 'w1) (rect 0 0 10 5))
(check-equal? (c-rect content2 'w2) (rect 11 1 8 3))
(check-equal? (map border-run-col (runs-at runs2 1)) '(10 19))

;; 全部无边框 → 没有边框行、内容不内缩
(define t3 (layout-set-pane-border t2 'w2 #f))
(define-values (content3 runs3) (border-plan t3 ps))
(check-equal? runs3 '())
(check-equal? (c-rect content3 'w1) (rect 0 0 10 5))

;; ---- 主题：命名 face → 真彩色 / 256 色 ----
(check-true (regexp-match? #rx"38;2;105;112;128" (face-bytes 'window-border)))   ; 真彩色
(check-true (regexp-match? #rx"38;5;196" (face-bytes (style 196 #f '()))))       ; 256 色
(check-equal? (face-bytes 'no-such-face) #"")                                    ; 未命名 → 无样式
(check-true (> (bytes-length (face-bytes 'status)) 0))

(displayln "edit2/border.rkt: all tests passed")
